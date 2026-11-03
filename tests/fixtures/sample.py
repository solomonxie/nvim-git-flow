import os


def first(a, b):
    total = a + b
    return total


def second(items):
    out = []
    for item in items:
        out.append(item * 2)
    return out


def third(path):
    if os.path.exists(path):
        return open(path).read()
    return None


class Holder:
    def __init__(self, value):
        self.value = value

    def get(self):
        return self.value
