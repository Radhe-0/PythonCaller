from python_caller_server import action, send_output, run


@action('greet')
async def greet(data):
    name = data['name']
    age = data['age']

    result = {"text":f"Hello {name}!, you are {age} years old.", "age":age}

    await send_output(result)



@action('greet2')
async def greet2(data):
    try:
        name = data['name']
        age = int(data['age'])

        result = {"text":f"Hello {name}!, you are {age} years old.", "age":age}

        await send_output(result)

    except Exception as e:
        error_dict = {'error': str(e)}
        await send_output(error_dict)

run()

