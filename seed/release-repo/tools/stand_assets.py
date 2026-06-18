#!/usr/bin/env python3
"""Генерация features/index.json и meta.json в собранном webroot перед сборкой образа стенда."""
import os
import sys
import json
import datetime


def write_index(features_dir):
    if not os.path.isdir(features_dir):
        return
    files = sorted(
        f for f in os.listdir(features_dir)
        if f.endswith(".json") and f != "index.json"
    )
    with open(os.path.join(features_dir, "index.json"), "w") as f:
        json.dump({"files": files}, f, ensure_ascii=False, indent=2)


def main():
    web, env, date, branch, ids_csv = sys.argv[1:6]
    ids = [int(x) for x in ids_csv.split(",") if x.strip()]

    for sub in ("", "svc-a", "svc-b"):
        write_index(os.path.join(web, sub, "features") if sub else os.path.join(web, "features"))

    meta = {
        "train": date,
        "env": env,
        "branch": branch,
        "bts": ids,
        "generated": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    with open(os.path.join(web, "meta.json"), "w") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)


if __name__ == "__main__":
    main()
