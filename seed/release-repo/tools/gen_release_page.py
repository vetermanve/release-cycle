#!/usr/bin/env python3
"""Doc-as-code: страница релиза. Описания БТ тянутся из Jira по API (JIRA_URL)."""
import os
import sys
import json
import yaml
from urllib.request import urlopen
from urllib.error import URLError

JIRA = os.environ.get("JIRA_URL", "http://mock-jira")


def jira_issue(bt_id):
    """Вернуть (summary, status) из Jira по ключу BT-<id>."""
    url = "{}/rest/api/2/issue/BT-{}".format(JIRA, bt_id)
    try:
        with urlopen(url, timeout=5) as r:
            data = json.load(r)
        f = data.get("fields", {})
        summary = f.get("summary", "(нет summary)")
        status = (f.get("status") or {}).get("name", "?")
        return summary, status
    except (URLError, ValueError, OSError):
        return "(Jira недоступна)", "?"


def main():
    relrepo, date = sys.argv[1], sys.argv[2]
    conflict = sys.argv[3] if len(sys.argv) > 3 else ""
    with open(os.path.join(relrepo, "trains", date, "bt-set.yaml")) as f:
        bt = yaml.safe_load(f) or {}
    status = bt.get("status", "?")
    bts = bt.get("bts", [])

    lock_path = os.path.join(relrepo, "trains", date, "affected-repos.lock")
    affected = []
    if os.path.exists(lock_path):
        with open(lock_path) as f:
            affected = [l.strip() for l in f if l.strip()]

    out = []
    out.append("# Релиз-поезд {}".format(date))
    out.append("")
    out.append("- **Статус:** {}".format(status))
    out.append("- **Ветка:** dev/test/release-{}".format(date))
    out.append("- **Источник описаний БТ:** Jira ({})".format(JIRA))
    if conflict:
        out.append("- **КОНФЛИКТ:** {}".format(conflict))
    out.append("")
    out.append("## Состав (БТ из Jira)")
    out.append("")
    if bts:
        out.append("| БТ | Описание (Jira) | Статус (Jira) |")
        out.append("|----|-----------------|---------------|")
        for b in bts:
            bid = b["id"]
            summary, jstatus = jira_issue(bid)
            out.append("| [BT-{0}]({1}/rest/api/2/issue/BT-{0}) | {2} | {3} |".format(
                bid, JIRA, summary, jstatus))
    else:
        out.append("_пусто_")
    out.append("")
    out.append("## Затронутые репозитории")
    out.append("")
    out.append("_Миграции детектятся по факту: `*-migrations` репо в каталоге, попавшие в сборку,"
               " появятся ниже автоматически._")
    out.append("")
    if affected:
        out.append("```")
        out.extend(affected)
        out.append("```")
    else:
        out.append("_нет (или ещё не собрано)_")
    out.append("")
    print("\n".join(out))


if __name__ == "__main__":
    main()
