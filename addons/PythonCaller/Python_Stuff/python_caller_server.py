import asyncio
import json
import websockets
from websockets.server import serve
import inspect
import socket

handlers = {}
current_websocket = None
HOST = None
PORT = None


def action(action):
    def decorator(func):
        if action not in handlers:
            handlers[action] = {"func": func}
        func.action = action
        return func
    return decorator


async def send_output(data):
    try:
        caller_frame = inspect.currentframe().f_back
        caller_function = caller_frame.f_code.co_name
        action = str(caller_function)
        meta_data = handlers[caller_function]["metadata"]
        message = {'action': action, 'data': data, '__metadata__': meta_data}

        await current_websocket.send(json.dumps(message))
    except websockets.exceptions.ConnectionClosedOK:
        print("The connection was closed before sending the message.")


async def _handle_connection(websocket):
    global current_websocket
    current_websocket = websocket

    try:
        async for message_0 in websocket:
            message = _clean_str(str(message_0))
            request = eval(message)  # str to dict

            action = request['action']
            func = handlers[action]["func"]
            handlers[action]["metadata"] = request['__metadata__']
            await func(request['data'])
                
    except websockets.exceptions.ConnectionClosed:
        current_websocket = None
        print("Websocket has closed the connection")


def _clean_str(raw_text: str):
    i_1 = raw_text.find("{")
    i_2 = raw_text.rfind("}")
    message = raw_text[i_1 : i_2 +1]
    return message


def _get_available_port():
    for port in range(61550, 62000):  # Rango de puertos a intentar
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            try:
                s.bind(('localhost', port))
            except OSError:
                continue
            else:
                return port
    raise ValueError("No se encontró un puerto disponible en el rango especificado.")


async def _main():
    HOST = 'localhost'
    PORT = _get_available_port()
    
    async with serve(_handle_connection, HOST, PORT, max_size=None):
        print(f"Host: {HOST}\nPort: {PORT}\n\n")
        await asyncio.get_running_loop().create_future()


def run():
    try:
        asyncio.run(_main())

    except KeyboardInterrupt:
        print("minisocket stopped.")