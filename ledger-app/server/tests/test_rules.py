"""Behavioral tests for deterministic auto-classification rules."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.rules import RuleError, apply_rules, apply_rules_with_metadata


def transaction(**overrides):
    result = {
        "source": "wechat",
        "kind": "payment",
        "direction": "expense",
        "merchant": "星巴克 STARBUCKS",
        "description": "拿铁咖啡",
        "category": None,
        "tags": ["原标签"],
        "excluded": False,
        "exclusion_reason": None,
    }
    result.update(overrides)
    return result


class RuleEngineTests(unittest.TestCase):
    def test_conditions_are_and_keywords_are_case_insensitive(self) -> None:
        rule = {
            "id": "coffee",
            "priority": 10,
            "enabled": True,
            "conditions": {
                "source": "WECHAT",
                "kind": "payment",
                "direction": "expense",
                "merchant_contains": "starbucks",
                "description_contains": "拿铁",
            },
            "actions": {"category": "餐饮", "tags": ["咖啡", "咖啡"], "excluded": False},
        }
        original = transaction()
        result, applied = apply_rules_with_metadata(original, [rule])
        self.assertEqual(result["category"], "餐饮")
        self.assertEqual(result["tags"], ["咖啡"])
        self.assertEqual(applied, {"category": "coffee", "tags": "coffee", "excluded": "coffee"})
        self.assertIsNone(result["exclusion_reason"])
        self.assertIsNone(original["category"])
        self.assertEqual(original["tags"], ["原标签"])
        self.assertIsNone(apply_rules(transaction(source="alipay"), [rule])["category"])

    def test_priority_and_tie_break_are_independent_of_input_order(self) -> None:
        rules = [
            {"id": "z", "priority": 5, "conditions": {}, "actions": {"category": "Z"}},
            {"id": "a", "priority": 5, "conditions": {}, "actions": {"category": "A"}},
            {"id": "low", "priority": 20, "conditions": {}, "actions": {"category": "LOW", "tags": ["通用"]}},
        ]
        first = apply_rules(transaction(), rules)
        reversed_result = apply_rules(transaction(), reversed(rules))
        self.assertEqual(first, reversed_result)
        self.assertEqual(first["category"], "A")
        self.assertEqual(first["tags"], ["通用"])

    def test_manual_fields_win_when_rules_reapply(self) -> None:
        rules = [
            {
                "id": "specific", "priority": 1, "enabled": True,
                "conditions": {"merchant_contains": "星巴克"},
                "actions": {"category": "餐饮", "tags": ["咖啡"], "excluded": True},
            }
        ]
        edited = transaction(category="工作餐", excluded=False, exclusion_reason=None)
        result, applied = apply_rules_with_metadata(edited, rules, manual_fields={"category", "excluded"})
        self.assertEqual(result["category"], "工作餐")
        self.assertFalse(result["excluded"])
        self.assertEqual(result["tags"], ["咖啡"])
        self.assertEqual(applied, {"tags": "specific"})

    def test_exclusion_rule_can_include_transfer_but_not_closed_transaction(self) -> None:
        rule = {
            "id": "include-friend", "priority": 1,
            "conditions": {"kind": ["transfer", "red_packet"], "merchant_contains": "朋友"},
            "actions": {"excluded": False, "category": "人情往来"},
        }
        transfer = transaction(
            kind="transfer", merchant="朋友", excluded=True,
            exclusion_reason="default_transfer",
        )
        included = apply_rules(transfer, [rule])
        self.assertFalse(included["excluded"])
        self.assertIsNone(included["exclusion_reason"])
        self.assertEqual(included["category"], "人情往来")

        closed = transaction(
            kind="transfer", merchant="朋友", excluded=True,
            exclusion_reason="closed_or_failed",
        )
        unchanged_exclusion = apply_rules(closed, [rule])
        self.assertTrue(unchanged_exclusion["excluded"])
        self.assertEqual(unchanged_exclusion["exclusion_reason"], "closed_or_failed")
        self.assertEqual(unchanged_exclusion["category"], "人情往来")

    def test_disabled_rule_and_no_match_do_not_change_transaction(self) -> None:
        rules = [
            {"id": "disabled", "priority": 1, "enabled": False,
             "conditions": {}, "actions": {"category": "错误"}},
            {"id": "other-source", "priority": 2,
             "conditions": {"source": "alipay"}, "actions": {"category": "错误"}},
        ]
        original = transaction()
        self.assertEqual(apply_rules(original, rules), original)

    def test_rejects_unknown_or_ambiguous_rules(self) -> None:
        invalid = [
            {"id": "x", "conditions": {"regex": ".*"}, "actions": {"category": "A"}},
            {"id": "x", "conditions": {}, "actions": {"unrecognized": True}},
            {"id": "x", "priority": True, "conditions": {}, "actions": {"category": "A"}},
            {"id": "x", "conditions": {}, "actions": {"excluded": "false"}},
        ]
        for rule in invalid:
            with self.subTest(rule=rule):
                with self.assertRaises(RuleError):
                    apply_rules(transaction(), [rule])
        duplicate = {"id": "same", "conditions": {}, "actions": {"category": "A"}}
        with self.assertRaisesRegex(RuleError, "id 必须唯一"):
            apply_rules(transaction(), [duplicate, duplicate])


if __name__ == "__main__":
    unittest.main()
