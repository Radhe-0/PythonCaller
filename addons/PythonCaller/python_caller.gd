# python_caller.gd
# This file is part of: PythonCaller
# Copyright (c) 2024 Radhe-0
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the 
# "Software"), to deal in the Software without restriction, including 
# without limitation the rights to use, copy, modify, merge, publish, 
# distribute, sublicense, and/or sell copies of the Software, and to 
# permit persons to whom the Software is furnished to do so, subject to 
# the following conditions: 
#
# The above copyright notice and this permission notice shall be 
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, 
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF 
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. 
# IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY 
# CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, 
# TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE 
# SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
@icon("res://addons/PythonCaller/icon.svg")
class_name PythonCaller
extends Node
##The PythonCaller is a Godot Node that facilitates communication between a Godot project and a Python script. It allows you to execute a Python script and establish a connection using a WebSocket for bidirectional communication.
##[br][br] Example of use:
##[codeblock]func _ready():                                         
##    $PythonCaller.call_function("greet", data)
##
## func pyhandler(output):
##    if output["action"] == "greet":
##    print("Here is your greet: ", output["data"])[/codeblock]
## Please check the github repo for the code in Python

## Emitted when a message is received from the Python script. [br] [br]
## [param output] - [Dictionary] with the received data from Python
signal pyhandler(output: Dictionary)

## Emitted when a successful connection is established with the Python server. [br] [br]
## [param attemps] - Indicates the number of attempts made before establishing the connection. [br]
## [param port] - It is the server and web client's port
signal pyconnected(attemps: int, port: int)

## Emitted when the connection with the Python server is lost.
signal pydisconnected()

## Emitted when latency exceeds the maximum allowed threshold. [br] [br]
## [param latency] - Current latency in milliseconds.
signal high_latency(latency: float)

## The Python script to execute.
## Use the file selector to choose a '.py' file.
@export_file("*.py") var python_file

## The path to the Python interpreter used to run the script.
## Use a Python interpreter from a virtual environment.
@export_file("*") var python_interpreter

## [i](Only in export).[/i] [br]The name of the executable that will be in the folder of the game.
## This file will contain all the dependencies needed to run the Python script.
## It is recommended to use PyInstaller to generate the executable. [br] (e.g [b]main.exe[/b] in Windows)
@export var executable_file_name: String

## Determines whether the Python service should start automatically when the scene is loaded.
@export var auto_start: bool = true

## The maximum number of reconnection attempts to make before giving up.
@export var max_reconnect_attemps: int = 100

## The maximum allowed latency threshold in milliseconds.
## If the latency exceeds this value, the `high_latency` signal will be emitted.
@export var max_latency_threshold: float = 500.0

## If enabled, the Python service will not be started automatically, and you will need to connect to an external Python process manually.
@export var external_debug: bool = false

var _process_id
var _socket_client
var _max_reconnect_attemps := max_reconnect_attemps
var _reconnect_attemps_so_far := 0
var _latency_timers := {}
var _port
var _random := RandomNumberGenerator.new()

func _init() -> void:
	add_to_group("PythonCaller")
	_random.randomize()

func _ready() -> void:
	var group_nodes = get_tree().get_nodes_in_group("PythonCaller")
	await _get_available_port()
	if len(group_nodes) > 1:
		push_error("No puedes colocar más de un PythonCaller por escena")
	else:
		set_process(false)
		set_physics_process(false)
		tree_exiting.connect(_on_tree_exiting)
		if auto_start:
			_connect_godot_to_python()

## Calls an action in the Python script with the specified data. [br] [br]
## [param action] - The name of the action to call. [br]
## [param data] - The data to pass to the function. Should be compatible with JSON
func call_function(action: String, data) -> void:
	var tick_id := _generate_tick_id()
	var message := {"action": action, "data": data, "__metadata__": {"tick_id": tick_id}}
	_socket_client.send_text(JSON.stringify(message))

	var latency_timer = Timer.new()
	latency_timer.timeout.connect(_on_latency_timeout.bind(tick_id))
	latency_timer.wait_time = max_latency_threshold / 1000.0
	add_child(latency_timer)
	_latency_timers[tick_id] = latency_timer
	latency_timer.start()

## Sets a new Python script to execute.
## Terminates the previous Python server process and restarts a new process with the new script.
## [br][br]
## [param file_path] - The file path of the new Python script. It must have the '.py' extension.
func set_new_python_script(file_path) -> void:
	if file_path.get_extension() == "py":
		python_file = file_path
		if _process_id != null:
			OS.kill(_process_id)
			_process_id = null
			_connect_godot_to_python()
	else:
		push_error("The file must have a '.py' extension")

## Sets a new Python interpreter to run the script.
## Terminates the previous Python server process and restarts a new process with the new interpreter.
## [br][br]
## [param interpreter_path] - The path of the new Python interpreter. It must not have a file extension.
func set_new_interpreter(interpreter_path) -> void:
	if interpreter_path.get_extension() == "":
		python_interpreter = interpreter_path
		_kill_server_process()
		_connect_godot_to_python()
	else:
		push_error("The interpreter path must not have an extension")

## Sets a new executable file containing the dependencies to run the Python script.
## Terminates the previous Python server process and restarts a new process with the new executable.
## [br][br]
## [param executable_name] - The name of the new executable file.
func set_new_executable(executable_name) -> void:
	executable_file_name = executable_name
	_kill_server_process()
	_connect_godot_to_python()

## Gets the number of reconnection attempts made so far.
## [br][br]
## [returns] - An integer representing the number of reconnection attempts made.
func get_reconnect_attemps() -> int:
	return _reconnect_attemps_so_far

## Sets the maximum number of reconnection attempts allowed.
## [param max_attemps] - The new maximum number of reconnection attempts.
func set_max_reconnect_attemps(max_attemps: int) -> void:
	max_reconnect_attemps = max_attemps
	_max_reconnect_attemps = max_attemps

## Starts the Python service if it's not running.
func start_python_service() -> void:
	if not is_python_service_running():
		_connect_godot_to_python()

## Stops the Python service if it's running.
func stop_python_service() -> void:
	if is_python_service_running():
		_kill_server_process()

## Checks if the Python service is currently running.
## [returns] - A boolean indicating whether the Python service is running or not.
func is_python_service_running() -> bool:
	return _process_id != null

func _connect_godot_to_python() -> void:
	if not external_debug:
		if OS.has_feature("editor"):
			var interpreter_path = ProjectSettings.globalize_path(python_interpreter)
			var file_path = ProjectSettings.globalize_path(python_file)
			_process_id = OS.create_process(interpreter_path, [file_path])
			_put_websocket(_port)
		elif OS.has_feature("linux"):
			_process_id = OS.create_process("./" + executable_file_name, [])
			_put_websocket(_port)
		elif OS.has_feature("windows"):
			_process_id = OS.create_process(executable_file_name, [])
			_put_websocket(_port)
	else:
		print("[PythonCaller] External debug is Available...\n")
		_put_websocket(_port)

func _put_websocket(port) -> void:
	_socket_client = WebSocketClient.new()
	add_child(_socket_client)
	_socket_client.url_server = "ws://localhost:" + str(port)
	_socket_client.text_received.connect(_handler)
	_socket_client.connection_established.connect(_server_connected)
	_socket_client.connection_closed.connect(_server_closed)

func _get_available_port():
	var server = WebSocketServer.new()
	
	if external_debug:
		for port in range(61550, 62000):
			var err = server.listen(port)
			if err != OK:
				_port = port
				server.queue_free()
				return
	else:
		for port in range(61550, 62000):
			var err = server.listen(port)
			if err == OK:
				_port = port
				server.queue_free()
				return


func _kill_server_process() -> void:
	if _process_id != null and not external_debug:
		OS.kill(_process_id)
		_process_id = null
		emit_signal("pydisconnected")

func _generate_tick_id() -> String:
	var id = _random.randi_range(0, 99)
	return str(id)

func _handler(_peer: WebSocketPeer, message) -> void:
	var output = JSON.parse_string(message)
	var tick_id = output["__metadata__"]["tick_id"]
	var latency
	var latency_timer = _latency_timers[tick_id]
	var max_l = max_latency_threshold / 1000.0
	var t_left = latency_timer.time_left
	
	if latency_timer.has_meta("timeouts"):
		var timeouts = latency_timer.get_meta("timeouts")
		var float_part = max_l - t_left
		latency = max_l * timeouts + float_part
	else:
		latency = max_l - t_left
	
	output["__metadata__"]["latency_secs"] = latency
	latency_timer.stop()
	latency_timer.queue_free()
	_latency_timers.erase(tick_id)

	emit_signal("pyhandler", output)

func _on_latency_timeout(tick_id) -> void:
	var l_timer = _latency_timers[tick_id]
	
	if l_timer.has_meta("timeouts"):
		var timeouts = l_timer.get_meta("timeouts")
		l_timer.set_meta("timeouts", timeouts + 1)
	else:
		emit_signal("high_latency", tick_id)
		l_timer.set_meta("timeouts", 1)

func _server_closed(_was_clean_closed) -> void:
	_attempt_reconnect()

func _server_connected(_peer : WebSocketPeer, _protocol : String) -> void:
	emit_signal("pyconnected", _reconnect_attemps_so_far, _port)

func _notification(what) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and external_debug:
		_kill_server_process()

func _attempt_reconnect() -> void:
	remove_child(_socket_client)
	_put_websocket(_port)
	_reconnect_attemps_so_far += 1
	
	if _reconnect_attemps_so_far == _max_reconnect_attemps:
		var pyfile_name = python_file.get_file()
		emit_signal("pydisconnected")
		push_warning("It seems there were too many attempts to establish a connection with the Python miniserver. Run " + pyfile_name + " manually to see more details.")

func _on_tree_exiting() -> void:
	_kill_server_process()

