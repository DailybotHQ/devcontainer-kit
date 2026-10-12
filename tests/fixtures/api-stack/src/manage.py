"""A stand-in for a product API's manage.py: no framework, no network."""
import sys
import time


def main(argv):
    if argv[1:2] == ["runserver"]:
        print("fixture api: serving (sleeping)", flush=True)
        while True:
            time.sleep(3600)
    print("fixture api: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
