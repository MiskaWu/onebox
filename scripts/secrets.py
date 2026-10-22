#!/usr/bin/env python3
"""Edit a flat `key: "value"` secrets.yml without sed.

    secrets.py gen     FILE KEY [LENGTH]   store a random URL-safe value
    secrets.py set     FILE KEY            read a value without echo (getpass)
    secrets.py show    FILE KEY            print the value
    secrets.py missing FILE                list keys still holding a CHANGE-ME placeholder

Values are written as YAML double-quoted scalars, so characters such as & | \\ " survive.
An ansible-vault encrypted file is refused: decrypt, edit, encrypt again.
Standard library only, on purpose: it must run on a bare host before anything is installed.
"""

import getpass
import json
import os
import re
import secrets
import sys
import tempfile

PLACEHOLDER = "CHANGE-ME"
LINE = re.compile(r'^(?P<key>[A-Za-z_][A-Za-z0-9_]*):(?P<rest>.*)$')


def die(msg):
    print(f"secrets.py: {msg}", file=sys.stderr)
    sys.exit(1)


def read_lines(path):
    if not os.path.exists(path):
        die(f"{path} does not exist (make init ENV=<name> creates it)")
    with open(path, encoding="utf-8") as f:
        text = f.read()
    if text.startswith("$ANSIBLE_VAULT"):
        die(f"{path} is vault-encrypted: ansible-vault decrypt it, edit, then encrypt again")
    return text.splitlines(keepends=True)


def parse_value(rest):
    rest = rest.strip()
    if not rest:
        return ""
    if rest[0] == '"':
        # json.loads understands the YAML double-quoted subset we write.
        end = rest.rfind('"')
        return json.loads(rest[: end + 1])
    if rest[0] == "'":
        end = rest.rfind("'")
        return rest[1:end].replace("''", "'")
    return rest.split(" #", 1)[0].strip()


def find(lines, key):
    for i, line in enumerate(lines):
        m = LINE.match(line)
        if m and m.group("key") == key:
            return i, parse_value(m.group("rest"))
    return None, None


def write_value(path, key, value):
    lines = read_lines(path)
    idx, _ = find(lines, key)
    new_line = f"{key}: {json.dumps(value, ensure_ascii=False)}\n"
    if idx is None:
        if lines and not lines[-1].endswith("\n"):
            lines[-1] += "\n"
        lines.append(new_line)
    else:
        lines[idx] = new_line
    directory = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".secrets.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.writelines(lines)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise
    print(f"{key} written to {path}")


def require_key(key):
    if not key or not LINE.match(f"{key}:"):
        die("KEY=<name> is required (letters, digits and _)")


def main(argv):
    if len(argv) < 3:
        die(__doc__.strip())
    cmd, path = argv[1], argv[2]
    key = argv[3] if len(argv) > 3 else ""

    if cmd == "gen":
        require_key(key)
        length = int(argv[4]) if len(argv) > 4 and argv[4] else 32
        write_value(path, key, secrets.token_urlsafe(length)[:length])
    elif cmd == "set":
        require_key(key)
        value = getpass.getpass(f"{key}: ")
        if not value:
            die("empty value, nothing written")
        write_value(path, key, value)
    elif cmd == "show":
        require_key(key)
        _, value = find(read_lines(path), key)
        if value is None:
            die(f"{key} is not in {path}")
        print(value)
    elif cmd == "missing":
        lines = read_lines(path)
        missing = []
        for line in lines:
            m = LINE.match(line)
            if m and parse_value(m.group("rest")).startswith(PLACEHOLDER):
                missing.append(m.group("key"))
        print("\n".join(missing) if missing else "no placeholders left")
    else:
        die(f"unknown command {cmd}")


if __name__ == "__main__":
    main(sys.argv)
