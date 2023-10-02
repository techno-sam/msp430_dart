#!/usr/bin/python3
while True:
    try:
        a = input("")
    except EOFError:
        print("EOF")
        break
    print(f"{a=}")