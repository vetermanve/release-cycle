#!/usr/bin/env python3
"""Каденс поездов: вычисление ближайшей даты поезда по schedule.yaml и симулированным часам."""
import sys
import datetime
import yaml


def next_train(clock, sched):
    mode = sched.get("mode", "biweekly")
    if mode == "biweekly":
        days = sched.get("biweekly_days", [2, 4])
    else:  # daily -> рабочие дни
        days = sched.get("workdays", [1, 2, 3, 4, 5])
    d = datetime.date.fromisoformat(clock)
    for i in range(1, 15):
        cand = d + datetime.timedelta(days=i)
        if cand.isoweekday() in days:
            return cand
    return None


def main():
    cmd = sys.argv[1]
    if cmd == "next":
        clock, schedpath = sys.argv[2], sys.argv[3]
        with open(schedpath) as f:
            sched = yaml.safe_load(f) or {}
        nt = next_train(clock, sched)
        print(nt.strftime("%y.%m.%d"))
    elif cmd == "advance":
        clock, days = sys.argv[2], int(sys.argv[3])
        d = datetime.date.fromisoformat(clock) + datetime.timedelta(days=days)
        print(d.isoformat())
    else:
        sys.exit("usage: cadence.py next <clock> <schedule.yaml> | advance <clock> <days>")


if __name__ == "__main__":
    main()
