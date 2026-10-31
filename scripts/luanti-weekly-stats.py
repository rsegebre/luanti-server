#!/usr/bin/env python3
"""Turn Luanti join/leave lines into a weekly activity summary.

The SSH forced command already dropped every other log line. This script
pairs joins and leaves per player and counts allowlist rejections. It does
not copy IP addresses or raw log lines into the JSON.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

WINDOW_DAYS = 7

TS_RE = re.compile(
    r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?"
)
JOIN_RE = re.compile(
    r"(?P<name>[A-Za-z0-9_-]{1,20}) \[[^\]]+\] joins game\. List of players:"
)
LEAVE_RE = re.compile(
    r"(?P<name>[A-Za-z0-9_-]{1,20}) leaves game\. List of players:"
)
REJECT_RE = re.compile(
    r"\[player_allowlist\] rejected name '(?P<name>[^']*)'"
)


class ParseError(Exception):
    pass


def parse_ts(raw: str) -> datetime:
    text = raw.strip().replace(" ", "T", 1)
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    offset = re.search(r"([+-]\d{2})(\d{2})$", text)
    if offset and text[-3] != ":":
        text = text[: offset.start()] + f"{offset.group(1)}:{offset.group(2)}"
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?", text):
        text += "+00:00"
    parsed = datetime.fromisoformat(text)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def iso_z(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def minutes(seconds: float) -> float:
    return round(seconds / 60.0, 1)


def parse_log(text: str, generated_at: datetime) -> dict:
    if generated_at.tzinfo is None:
        generated_at = generated_at.replace(tzinfo=timezone.utc)
    generated_at = generated_at.astimezone(timezone.utc).replace(microsecond=0)
    window_start = generated_at - timedelta(days=WINDOW_DAYS)
    window_end = generated_at
    future_limit = generated_at + timedelta(minutes=10)

    seconds: dict[str, float] = {}
    sessions: dict[str, int] = {}
    open_at: dict[str, datetime] = {}
    rejected: dict[str, int] = {}
    unparsed = 0

    def add_session(name: str, start: datetime, end: datetime) -> None:
        if end < start:
            end = start
        seconds[name] = seconds.get(name, 0.0) + (end - start).total_seconds()
        sessions[name] = sessions.get(name, 0) + 1

    for line in text.splitlines():
        if not line.strip():
            continue
        ts_match = TS_RE.search(line)
        if ts_match is None:
            unparsed += 1
            continue
        try:
            when = parse_ts(ts_match.group(0))
        except ValueError:
            unparsed += 1
            continue
        if when < window_start or when > future_limit:
            continue

        reject = REJECT_RE.search(line)
        join = JOIN_RE.search(line)
        leave = LEAVE_RE.search(line)
        if reject:
            name = reject.group("name") or "(empty)"
            rejected[name] = rejected.get(name, 0) + 1
            continue
        if join:
            name = join.group("name")
            if name in open_at:
                add_session(name, open_at[name], when)
            open_at[name] = when
            continue
        if leave:
            name = leave.group("name")
            start = open_at.pop(name, window_start)
            add_session(name, start, when)
            continue
        unparsed += 1

    if unparsed:
        raise ParseError(
            f"{unparsed} log line(s) did not match a join, a leave, or a rejected name"
        )

    for name, start in open_at.items():
        add_session(name, start, window_end)

    players = [
        {
            "name": name,
            "sessions": sessions[name],
            "play_minutes": minutes(seconds[name]),
        }
        for name in sorted(seconds, key=lambda item: (-seconds[item], item))
    ]
    rejected_joins = [
        {"name": name, "attempts": rejected[name]}
        for name in sorted(rejected, key=lambda item: (-rejected[item], item))
    ]
    return {
        "generated_at": iso_z(generated_at),
        "window_days": WINDOW_DAYS,
        "window_start": iso_z(window_start),
        "window_end": iso_z(window_end),
        "players": players,
        "rejected_joins": rejected_joins,
        "totals": {
            "players": len(players),
            "sessions": sum(sessions.values()),
            "play_minutes": minutes(sum(seconds.values())),
            "rejected_attempts": sum(rejected.values()),
        },
    }


def render_summary(report: dict) -> str:
    lines = [
        "## Luanti weekly player activity",
        "",
        f"Window {report['window_start']} to {report['window_end']} (UTC).",
        "",
        "| Player | Sessions | Play minutes |",
        "| --- | ---: | ---: |",
    ]
    if report["players"]:
        for player in report["players"]:
            name = str(player["name"]).replace("|", "\\|").replace("\n", " ")
            lines.append(
                f"| {name} | {player['sessions']} | {player['play_minutes']} |"
            )
    else:
        lines.append("| (none) | 0 | 0 |")
    lines.extend(
        [
            "",
            "| Rejected name | Attempts |",
            "| --- | ---: |",
        ]
    )
    if report["rejected_joins"]:
        for item in report["rejected_joins"]:
            name = str(item["name"]).replace("|", "\\|").replace("\n", " ")
            lines.append(f"| {name} | {item['attempts']} |")
    else:
        lines.append("| (none) | 0 |")
    lines.extend(
        [
            "",
            "```json",
            json.dumps(report, indent=2),
            "```",
            "",
        ]
    )
    return "\n".join(lines)


def self_test() -> None:
    generated = datetime(2026, 10, 31, 2, 30, tzinfo=timezone.utc)
    sample = "\n".join(
        [
            "2026-10-01T00:00:00+0000 luanti luanti-run[1]: 2026-10-01 00:00:00: ACTION[Server]: old [10.0.0.1] joins game. List of players: old",
            "2026-10-24T03:00:00+0000 luanti luanti-run[1]: 2026-10-24 03:00:00: ACTION[Server]: rss1989 [73.92.174.251] joins game. List of players: rss1989",
            "2026-10-24T04:30:00+0000 luanti luanti-run[1]: 2026-10-24 04:30:00: ACTION[Server]: rss1989 leaves game. List of players:",
            "2026-10-30T10:00:00.100000000Z 2026-10-30 10:00:00: ACTION[Server]: rss1989 [73.92.174.251] joins game. List of players: rss1989",
            "2026-10-30T10:20:00+0000 luanti luanti-run[1]: 2026-10-30 10:20:00: ACTION[Server]: rss1989 leaves game. List of players:",
            "2026-10-31T01:00:00+0000 luanti luanti-run[1]: 2026-10-31 01:00:00: ACTION[Server]: friend [73.92.174.251] joins game. List of players: friend",
            "2026-10-24T03:30:00+0000 luanti luanti-run[1]: 2026-10-24 03:30:00: ACTION[Server]: guest leaves game. List of players:",
            "2026-10-24T05:00:00+0000 luanti luanti-run[1]: 2026-10-24 05:00:00: ACTION[Server]: [player_allowlist] rejected name 'NotAFriend' from 203.0.113.10",
            "2026-10-25T05:00:00+0000 luanti luanti-run[1]: 2026-10-25 05:00:00: ACTION[Server]: [player_allowlist] rejected name 'NotAFriend' from 203.0.113.10",
            "2026-10-26T05:00:00+0000 luanti luanti-run[1]: 2026-10-26 05:00:00: ACTION[Server]: [player_allowlist] rejected name 'Other' from 198.51.100.20",
            "2026-10-24T06:00:00+0000 luanti luanti-run[1]: 2026-10-24 06:00:00: ACTION[Server]: rss1989 [73.92.174.251] joins game. List of players: rss1989",
            "2026-10-24T06:01:30+0000 luanti luanti-run[1]: 2026-10-24 06:01:30: ACTION[Server]: rss1989 leaves game. List of players:",
        ]
    )
    report = parse_log(sample, generated)
    encoded = json.dumps(report)
    for secret in ("73.92.174.251", "203.0.113.10", "198.51.100.20", "10.0.0.1"):
        if secret in encoded:
            raise SystemExit(f"summary leaked an address: {secret}")
    by_name = {player["name"]: player for player in report["players"]}
    if by_name["rss1989"] != {"name": "rss1989", "sessions": 3, "play_minutes": 111.5}:
        raise SystemExit(f"rss1989 summary mismatch: {by_name['rss1989']}")
    if by_name["friend"] != {"name": "friend", "sessions": 1, "play_minutes": 90.0}:
        raise SystemExit(f"open session mismatch: {by_name['friend']}")
    if by_name["guest"] != {"name": "guest", "sessions": 1, "play_minutes": 60.0}:
        raise SystemExit(f"leave-only session mismatch: {by_name['guest']}")
    if "old" in by_name:
        raise SystemExit("event before the window was counted")
    rejected = {item["name"]: item["attempts"] for item in report["rejected_joins"]}
    if rejected != {"NotAFriend": 2, "Other": 1}:
        raise SystemExit(f"rejected summary mismatch: {rejected}")
    if report["totals"] != {
        "players": 3,
        "sessions": 5,
        "play_minutes": 261.5,
        "rejected_attempts": 3,
    }:
        raise SystemExit(f"totals mismatch: {report['totals']}")
    if "73.92.174.251" in render_summary(report):
        raise SystemExit("job summary leaked an address")
    empty = parse_log("", generated)
    if empty["players"] or empty["rejected_joins"] or empty["totals"]["sessions"] != 0:
        raise SystemExit(f"empty week mismatch: {empty}")
    try:
        parse_log("2026-10-24T03:00:00+0000 not a join line\n", generated)
    except ParseError:
        pass
    else:
        raise SystemExit("unrecognized line was accepted")
    print("luanti-weekly-stats self-test passed")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, help="Filtered log lines")
    parser.add_argument("--output", type=Path, help="JSON summary path")
    parser.add_argument(
        "--summary",
        type=Path,
        help="Optional Markdown job summary to append",
    )
    parser.add_argument(
        "--generated-at",
        help="UTC timestamp YYYY-MM-DDTHH:MM:SSZ. Defaults to now.",
    )
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if args.input is None or args.output is None:
        parser.error("--input and --output are required")
    if args.generated_at:
        generated_at = parse_ts(args.generated_at)
    else:
        generated_at = datetime.now(timezone.utc)
    try:
        report = parse_log(args.input.read_text(encoding="utf-8", errors="replace"), generated_at)
    except ParseError as exc:
        sys.exit(str(exc))
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    if args.summary is not None:
        with args.summary.open("a", encoding="utf-8") as handle:
            handle.write(render_summary(report))
    print(
        f"players={report['totals']['players']} "
        f"sessions={report['totals']['sessions']} "
        f"play_minutes={report['totals']['play_minutes']} "
        f"rejected={report['totals']['rejected_attempts']}"
    )


if __name__ == "__main__":
    main()
