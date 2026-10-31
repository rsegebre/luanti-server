#!/usr/bin/env python3
"""Refuse a firewall plan that changes anything except one SSH host.

The weekly stats job opens SSH for the runner /32 and then removes it.
Both applies are saved plans of linode_firewall.luanti. This check fails
the job before apply unless that plan's only effect is adding the runner
(open) or removing it (close).
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

FIREWALL = "linode_firewall.luanti"
# Computed attributes. A change here is not something this job would be
# choosing, and Terraform still sends them through on an in-place update.
COMPUTED = {"id", "status", "created", "updated", "devices"}
SSH_LABEL = {"ipv4": "ssh-v4", "ipv6": "ssh-v6"}


class PlanRejected(Exception):
    pass


def same(left, right) -> bool:
    if canon(left) == canon(right):
        return True
    # Terraform uses null and [] for the same empty collection depending
    # on which side of the plan the value came from.
    return left in (None, [], {}) and right in (None, [], {})


def canon(value):
    if value is None:
        return None
    if isinstance(value, list):
        if value and all(isinstance(item, dict) and "label" in item for item in value):
            return {
                item["label"]: canon(
                    {key: item[key] for key in item if key != "label"}
                )
                for item in value
            }
        return sorted(
            (canon(item) for item in value),
            key=lambda item: json.dumps(item, sort_keys=True, default=str),
        )
    if isinstance(value, dict):
        return {key: canon(value[key]) for key in sorted(value)}
    return value


def load_admin_cidrs(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8")
    match = re.search(r"(?m)^admin_cidrs\s*=\s*\[(.*?)\n\]", text, re.S)
    if not match:
        raise PlanRejected(f"could not find admin_cidrs in {path}")
    cidrs = re.findall(r'"([^"]+)"', match.group(1))
    if not cidrs:
        raise PlanRejected("admin_cidrs is empty")
    return cidrs


def rules_by_label(resource: dict) -> dict[str, dict]:
    inbound = resource.get("inbound") or []
    if not isinstance(inbound, list):
        raise PlanRejected("firewall inbound rules are not a list")
    rules: dict[str, dict] = {}
    for rule in inbound:
        if not isinstance(rule, dict):
            raise PlanRejected("firewall inbound rule is not an object")
        label = rule.get("label")
        if not isinstance(label, str) or not label or label in rules:
            raise PlanRejected(f"firewall inbound rule has a bad label: {label!r}")
        rules[label] = rule
    return rules


def address_set(rule: dict | None, family: str) -> set[str]:
    if rule is None:
        return set()
    value = rule.get(family)
    if value is None:
        return set()
    if isinstance(value, str):
        return {value}
    if not isinstance(value, list):
        raise PlanRejected(f"firewall {family} addresses are not a list")
    return {str(item) for item in value}


def rule_without_addresses(rule: dict) -> dict:
    return {key: value for key, value in rule.items() if key not in {"ipv4", "ipv6"}}


def assert_tcp_22(rule: dict) -> None:
    action = str(rule.get("action", "")).upper()
    protocol = str(rule.get("protocol", "")).upper()
    ports = rule.get("ports")
    if action != "ACCEPT" or protocol != "TCP" or str(ports) != "22":
        raise PlanRejected("SSH rule is not TCP port 22 ACCEPT")


def check_firewall_body(
    before: dict,
    after: dict,
    runner: str,
    mode: str,
    admin_cidrs: list[str],
) -> str:
    if mode not in {"open", "close"}:
        raise PlanRejected("mode must be open or close")
    family = "ipv6" if ":" in runner else "ipv4"
    other = "ipv6" if family == "ipv4" else "ipv4"
    suffix = "/128" if family == "ipv6" else "/32"
    if not runner.endswith(suffix):
        raise PlanRejected(f"runner CIDR must be a single host ({suffix})")
    label = SSH_LABEL[family]

    keys = (set(before) | set(after)) - COMPUTED - {"inbound"}
    for key in sorted(keys):
        if not same(before.get(key), after.get(key)):
            raise PlanRejected(f"firewall attribute {key} would change")

    before_rules = rules_by_label(before)
    after_rules = rules_by_label(after)
    before_rule = before_rules.get(label)
    after_rule = after_rules.get(label)
    before_set = address_set(before_rule, family)
    after_set = address_set(after_rule, family)
    runner_is_admin = runner in set(admin_cidrs)

    if mode == "open":
        if runner_is_admin or runner in before_set:
            expected = set(before_set)
            changing = False
        else:
            expected = set(before_set)
            expected.add(runner)
            changing = True
    else:
        if runner_is_admin or runner not in before_set:
            expected = set(before_set)
            changing = False
        else:
            expected = set(before_set)
            expected.discard(runner)
            changing = True

    if after_set != expected:
        raise PlanRejected(
            f"{label} {family} would change by more than "
            f"{'adding' if mode == 'open' else 'removing'} {runner}"
        )
    if address_set(before_rule, other) != address_set(after_rule, other):
        raise PlanRejected(f"{label} {other} addresses would change")

    before_labels = set(before_rules)
    after_labels = set(after_rules)
    if before_rule is None and after_rule is not None:
        if mode != "open" or after_set != {runner}:
            raise PlanRejected(f"plan would add firewall rule {label}")
        assert_tcp_22(after_rule)
    elif before_rule is not None and after_rule is None:
        if mode != "close" or before_set != {runner}:
            raise PlanRejected(f"plan would remove firewall rule {label}")
    elif before_rule is not None and after_rule is not None:
        if not same(
            rule_without_addresses(before_rule),
            rule_without_addresses(after_rule),
        ):
            raise PlanRejected(f"{label} would change a field other than its address list")

    extra_before = before_labels - after_labels - {label}
    extra_after = after_labels - before_labels - {label}
    if extra_before or extra_after:
        raise PlanRejected(
            "firewall rules other than SSH would be added or removed: "
            + ", ".join(sorted(extra_before | extra_after))
        )
    for rule_label in sorted(before_labels & after_labels - {label}):
        if not same(before_rules[rule_label], after_rules[rule_label]):
            raise PlanRejected(f"firewall rule {rule_label} would change")

    if changing:
        if mode == "open":
            return f"ok: firewall SSH allowlist add {runner}"
        return f"ok: firewall SSH allowlist remove {runner}"
    if runner_is_admin:
        return f"ok: {runner} is already an admin CIDR; firewall unchanged"
    if mode == "open":
        return f"ok: {runner} is already on the SSH allowlist; firewall unchanged"
    return f"ok: {runner} is not on the SSH allowlist; firewall unchanged"


def check_plan(plan: dict, runner: str, mode: str, admin_cidrs: list[str]) -> tuple[str, bool]:
    changes = plan.get("resource_changes")
    if not isinstance(changes, list):
        raise PlanRejected("plan JSON has no resource_changes")
    firewall = None
    for change in changes:
        address = change.get("address")
        actions = change.get("change", {}).get("actions")
        if address != FIREWALL:
            if actions not in (["no-op"], ["read"]):
                raise PlanRejected(f"{address} would change ({actions})")
            continue
        if firewall is not None:
            raise PlanRejected("plan contains more than one firewall change")
        firewall = change
    if firewall is None:
        raise PlanRejected(f"plan does not contain {FIREWALL}")

    actions = firewall.get("change", {}).get("actions")
    if actions == ["no-op"]:
        body = firewall["change"].get("before") or firewall["change"].get("after")
        if not isinstance(body, dict):
            raise PlanRejected("firewall no-op plan has no before/after body")
        try:
            message = check_firewall_body(body, body, runner, mode, admin_cidrs)
        except PlanRejected as exc:
            raise PlanRejected(
                "plan is a no-op but the SSH allowlist is not in the required state: "
                f"{exc}"
            ) from exc
        if "unchanged" not in message:
            raise PlanRejected("plan is a no-op but the SSH allowlist still needs an update")
        return message, False
    if actions != ["update"]:
        raise PlanRejected(f"firewall action {actions} is not an in-place update")

    before = firewall["change"].get("before")
    after = firewall["change"].get("after")
    if not isinstance(before, dict) or not isinstance(after, dict):
        raise PlanRejected("firewall update is missing before or after")
    message = check_firewall_body(before, after, runner, mode, admin_cidrs)
    if "unchanged" in message:
        raise PlanRejected(
            "plan updates the firewall without an allowed SSH allowlist change"
        )
    return message, True


def self_test() -> None:
    def rule(label, protocol, ports, ipv4, ipv6=None):
        return {
            "label": label,
            "action": "ACCEPT",
            "protocol": protocol,
            "ports": ports,
            "ipv4": ipv4,
            "ipv6": ipv6 or [],
        }

    admin = ["73.92.174.251/32", "2601:647:5b00:66a0::/64"]
    runner = "192.0.2.10/32"

    def body(ipv4):
        return {
            "id": "197317662",
            "label": "luanti-fw",
            "status": "enabled",
            "inbound_policy": "DROP",
            "outbound_policy": "ACCEPT",
            "tags": ["private", "luanti"],
            "linodes": [107695482],
            "outbound": [],
            "devices": [{"id": 1}],
            "inbound": [
                rule("icmp-v4", "ICMP", None, ["0.0.0.0/0"]),
                rule("ssh-v4", "TCP", "22", ipv4),
                rule("ssh-v6", "TCP", "22", [], ["2601:647:5b00:66a0::/64"]),
                rule("luanti-udp-v4", "UDP", "30000", ["73.92.174.251/32"]),
            ],
        }

    def plan_for(before_ips, after_ips, actions, extra=None):
        changes = [
            {
                "address": FIREWALL,
                "change": {
                    "actions": actions,
                    "before": body(before_ips),
                    "after": body(after_ips),
                },
            },
            {
                "address": "linode_instance.luanti",
                "change": {"actions": ["no-op"], "before": {}, "after": {}},
            },
        ]
        if extra:
            changes.append(extra)
        return {"resource_changes": changes}

    message, apply = check_plan(
        plan_for(["73.92.174.251/32"], ["73.92.174.251/32", runner], ["update"]),
        runner,
        "open",
        admin,
    )
    if not apply or runner not in message:
        raise SystemExit(f"open should add the runner: {message}")

    # Rule order and tag order must not look like a second change.
    reordered = plan_for(
        ["73.92.174.251/32"],
        [runner, "73.92.174.251/32"],
        ["update"],
    )
    reordered["resource_changes"][0]["change"]["after"]["tags"] = ["luanti", "private"]
    reordered["resource_changes"][0]["change"]["after"]["inbound"] = list(
        reversed(reordered["resource_changes"][0]["change"]["after"]["inbound"])
    )
    check_plan(reordered, runner, "open", admin)

    message, apply = check_plan(
        plan_for(
            ["73.92.174.251/32", runner],
            ["73.92.174.251/32"],
            ["update"],
        ),
        runner,
        "close",
        admin,
    )
    if not apply or "remove" not in message:
        raise SystemExit(f"close should remove the runner: {message}")

    message, apply = check_plan(
        plan_for(["73.92.174.251/32"], ["73.92.174.251/32"], ["no-op"]),
        runner,
        "close",
        admin,
    )
    if apply or "not on the SSH allowlist" not in message:
        raise SystemExit(f"close no-op mismatch: {message} apply={apply}")

    message, apply = check_plan(
        plan_for(
            ["73.92.174.251/32", runner],
            ["73.92.174.251/32", runner],
            ["no-op"],
        ),
        runner,
        "open",
        admin,
    )
    if apply or "already" not in message:
        raise SystemExit(f"open already-present mismatch: {message}")

    def expect_reject(plan, mode, text):
        try:
            check_plan(plan, runner, mode, admin)
        except PlanRejected as exc:
            if text not in str(exc):
                raise SystemExit(f"expected {text!r} in {exc}") from exc
        else:
            raise SystemExit(f"accepted a plan that should fail ({text})")

    udp = plan_for(
        ["73.92.174.251/32"],
        ["73.92.174.251/32", runner],
        ["update"],
    )
    udp["resource_changes"][0]["change"]["after"]["inbound"][3]["ipv4"] = [
        "198.51.100.9/32"
    ]
    expect_reject(udp, "open", "luanti-udp-v4")

    removed_home = plan_for(
        ["73.92.174.251/32"],
        [runner],
        ["update"],
    )
    expect_reject(removed_home, "open", "more than adding")

    other = plan_for(
        ["73.92.174.251/32"],
        ["73.92.174.251/32", runner],
        ["update"],
        extra={
            "address": "linode_instance.luanti",
            "change": {"actions": ["update"], "before": {}, "after": {}},
        },
    )
    expect_reject(other, "open", "linode_instance.luanti")

    replaced = plan_for(
        ["73.92.174.251/32"],
        ["73.92.174.251/32", runner],
        ["delete", "create"],
    )
    expect_reject(replaced, "open", "not an in-place update")

    expect_reject(
        plan_for(["73.92.174.251/32"], ["73.92.174.251/32"], ["no-op"]),
        "open",
        "no-op",
    )
    expect_reject(
        plan_for(
            ["73.92.174.251/32", runner],
            ["73.92.174.251/32", runner],
            ["update"],
        ),
        "close",
        "more than removing",
    )
    expect_reject(
        plan_for(["73.92.174.251/32"], ["73.92.174.251/32"], ["update"]),
        "close",
        "without an allowed",
    )

    home = "73.92.174.251/32"
    message, apply = check_plan(
        plan_for([home], [home], ["no-op"]),
        home,
        "close",
        admin,
    )
    if apply or "admin CIDR" not in message:
        raise SystemExit(f"close must not remove an admin CIDR: {message}")

    repo_cidrs = load_admin_cidrs(Path(__file__).resolve().parents[1] / "main" / "terraform.tfvars")
    if not repo_cidrs or any("/" not in cidr for cidr in repo_cidrs):
        raise SystemExit(f"could not parse admin_cidrs: {repo_cidrs}")
    print("ci-firewall-ssh-only self-test passed")


def main() -> None:
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        self_test()
        return
    if len(sys.argv) != 5:
        sys.exit(
            "usage: ci-firewall-ssh-only.py PLAN.json RUNNER_CIDR open|close TFVARS"
        )
    plan_path, runner, mode, tfvars = sys.argv[1:]
    try:
        plan = json.loads(Path(plan_path).read_text(encoding="utf-8"))
        message, _apply = check_plan(plan, runner, mode, load_admin_cidrs(Path(tfvars)))
    except (OSError, json.JSONDecodeError, PlanRejected) as exc:
        sys.exit(f"refusing to apply the firewall plan: {exc}")
    print(message)


if __name__ == "__main__":
    main()
