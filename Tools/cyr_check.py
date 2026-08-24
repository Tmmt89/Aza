import sys

src = open(sys.argv[1]).read()
for i, line in enumerate(src.split("\n"), 1):
    for ch in sorted(set(line)):
        if 0x400 <= ord(ch) <= 0x4FF:
            print(f"line {i}: U+{ord(ch):04X} {ch!r}")
