"""Deterministic, side-effect-free auto-classification of ledger transactions.

Rule shape::

    {
        "id": "stable-id",
        "priority": 10,                 # lower numbers run first
        "enabled": True,
        "conditions": {                # all supplied conditions must match
            "source": "wechat",        # exact, optionally a list of alternatives
            "kind": "payment",
            "direction": "expense",
            "merchant_contains": "coffee",  # case-insensitive substring
            "description_contains": "latte",
        },
        "actions": {"category": "餐饮", "tags": ["咖啡"], "excluded": False},
    }

For each action field, the first matching rule wins. A field listed in
``manual_fields`` is never changed by a rule. The backend must persist manual
field provenance and pass it again when reapplying rules.
"""

from __future__ import annotations

import unicodedata
from collections.abc import Collection, Iterable, Mapping
from typing import Any

__all__ = ["RuleError", "apply_rules", "apply_rules_with_metadata", "validate_rule"]

_EXACT_CONDITIONS = {"source", "kind", "direction"}
_CONTAINS_CONDITIONS = {"merchant_contains", "description_contains"}
_ACTIONS = {"category", "tags", "excluded"}


class RuleError(ValueError):
    """A rule has an unsupported or ambiguous shape."""


def _text(value: str) -> str:
    return unicodedata.normalize("NFKC", value).strip().casefold()


def _options(value: Any, label: str) -> tuple[str, ...]:
    if isinstance(value, str):
        options = (value,)
    elif isinstance(value, list) and value and all(isinstance(item, str) for item in value):
        options = tuple(value)
    else:
        raise RuleError(f"{label} 必须是非空字符串或非空字符串列表。")
    normalized = tuple(_text(item) for item in options)
    if any(not item for item in normalized):
        raise RuleError(f"{label} 不能包含空字符串。")
    return normalized


def validate_rule(rule: Mapping[str, Any]) -> None:
    """Reject unknown fields and invalid values before storing or applying a rule."""
    if not isinstance(rule, Mapping):
        raise RuleError("规则必须是对象。")
    unknown_top = set(rule) - {"id", "priority", "enabled", "conditions", "actions"}
    if unknown_top:
        raise RuleError(f"规则包含未知字段：{', '.join(sorted(unknown_top))}。")
    if not isinstance(rule.get("id"), str) or not rule["id"].strip():
        raise RuleError("规则必须有非空 id。")
    priority = rule.get("priority", 100)
    if isinstance(priority, bool) or not isinstance(priority, int):
        raise RuleError("priority 必须是整数，数字越小优先级越高。")
    if not isinstance(rule.get("enabled", True), bool):
        raise RuleError("enabled 必须是布尔值。")

    conditions = rule.get("conditions", {})
    if not isinstance(conditions, Mapping):
        raise RuleError("conditions 必须是对象。")
    unknown_conditions = set(conditions) - _EXACT_CONDITIONS - _CONTAINS_CONDITIONS
    if unknown_conditions:
        raise RuleError(f"未知匹配条件：{', '.join(sorted(unknown_conditions))}。")
    for field, value in conditions.items():
        _options(value, field)

    actions = rule.get("actions")
    if not isinstance(actions, Mapping) or not actions:
        raise RuleError("actions 必须包含至少一个操作。")
    unknown_actions = set(actions) - _ACTIONS
    if unknown_actions:
        raise RuleError(f"未知规则操作：{', '.join(sorted(unknown_actions))}。")
    if "category" in actions and actions["category"] is not None:
        if not isinstance(actions["category"], str) or not actions["category"].strip():
            raise RuleError("category 必须是非空字符串或 null。")
    if "tags" in actions:
        tags = actions["tags"]
        if not isinstance(tags, list) or any(not isinstance(tag, str) or not tag.strip() for tag in tags):
            raise RuleError("tags 必须是字符串列表，且不能包含空标签。")
    if "excluded" in actions and not isinstance(actions["excluded"], bool):
        raise RuleError("excluded 必须是布尔值。")


def _matches(transaction: Mapping[str, Any], rule: Mapping[str, Any]) -> bool:
    for field, wanted in rule.get("conditions", {}).items():
        options = _options(wanted, field)
        value_field = field.removesuffix("_contains")
        actual = _text(str(transaction.get(value_field) or ""))
        if field in _EXACT_CONDITIONS:
            if actual not in options:
                return False
        elif not any(option in actual for option in options):
            return False
    return True


def apply_rules_with_metadata(
    transaction: Mapping[str, Any],
    rules: Iterable[Mapping[str, Any]],
    manual_fields: Collection[str] = (),
) -> tuple[dict[str, Any], dict[str, str]]:
    """Return a new transaction and the winning rule ID for each changed field.

    A rule cannot make a closed or failed source transaction count in reports;
    its category and tags may still be set for later review.
    """
    if not isinstance(transaction, Mapping):
        raise RuleError("交易必须是对象。")
    ordered = list(rules)
    for rule in ordered:
        validate_rule(rule)
    ids = [rule["id"] for rule in ordered]
    if len(ids) != len(set(ids)):
        raise RuleError("规则 id 必须唯一。")
    ordered.sort(key=lambda rule: (rule.get("priority", 100), rule["id"]))

    result = dict(transaction)
    if isinstance(result.get("tags"), list):
        result["tags"] = list(result["tags"])
    protected = set(manual_fields)
    applied: dict[str, str] = {}
    for rule in ordered:
        if not rule.get("enabled", True) or not _matches(transaction, rule):
            continue
        for field, value in rule["actions"].items():
            if field in protected or field in applied:
                continue
            if field == "excluded" and transaction.get("exclusion_reason") == "closed_or_failed":
                continue
            if field == "tags":
                result[field] = list(dict.fromkeys(tag.strip() for tag in value))
            elif field == "category" and isinstance(value, str):
                result[field] = value.strip()
            else:
                result[field] = value
            if field == "excluded":
                result["exclusion_reason"] = f"rule:{rule['id']}" if value else None
            applied[field] = rule["id"]
        if len(applied | {field: "manual" for field in protected & _ACTIONS}) == len(_ACTIONS):
            break
    return result, applied


def apply_rules(
    transaction: Mapping[str, Any],
    rules: Iterable[Mapping[str, Any]],
    manual_fields: Collection[str] = (),
) -> dict[str, Any]:
    """Apply enabled rules without mutating the transaction or the rules."""
    result, _ = apply_rules_with_metadata(transaction, rules, manual_fields)
    return result
