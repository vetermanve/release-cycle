#!/usr/bin/env python3
"""Хелпер чтения/правки конфигов поезда (yaml/json/markdown) для CI-скриптов."""
import sys
import re
import json
import yaml


def load_yaml(path):
    with open(path) as f:
        return yaml.safe_load(f)


def cmd_status(path):
    print((load_yaml(path) or {}).get("status", ""))


def cmd_bts(path):
    data = load_yaml(path) or {}
    for bt in data.get("bts", []):
        print(bt["id"])


def cmd_bts_full(path):
    """id<TAB>migration на строку."""
    data = load_yaml(path) or {}
    for bt in data.get("bts", []):
        print("{}\t{}".format(bt["id"], bt.get("migration", "none")))


def cmd_field(path, key):
    print((load_yaml(path) or {}).get(key, ""))


def cmd_repos(path):
    data = load_yaml(path) or {}
    print(data.get("group", ""))
    for r in data.get("repos", []):
        print("{}\t{}".format(r["name"], r.get("mount", "")))


def cmd_set_status(path, status):
    with open(path) as f:
        text = f.read()
    if re.search(r"(?m)^status:.*$", text):
        text = re.sub(r"(?m)^status:.*$", "status: {}".format(status), text)
    else:
        text = text.rstrip() + "\nstatus: {}\n".format(status)
    with open(path, "w") as f:
        f.write(text)


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit("usage: cfg.py <cmd> ...")
    cmd, rest = args[0], args[1:]
    table = {
        "status": cmd_status,
        "bts": cmd_bts,
        "bts-full": cmd_bts_full,
        "field": cmd_field,
        "repos": cmd_repos,
        "set-status": cmd_set_status,
    }
    fn = table.get(cmd)
    if not fn:
        sys.exit("unknown cmd: {}".format(cmd))
    fn(*rest)


if __name__ == "__main__":
    main()
