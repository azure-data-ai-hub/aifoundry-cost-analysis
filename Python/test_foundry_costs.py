"""Offline checks for billing queries, attribution, token counts, and reports."""

import unittest
from datetime import date
from decimal import Decimal
from unittest.mock import Mock, patch

from foundry_costs import ArmClient, build_payload, build_report, get_cost_report, infer_model, query_costs, summarize, token_usage


ACCOUNT = "/subscriptions/sub/resourceGroups/rg/providers/Microsoft.CognitiveServices/accounts/ai"


def deployment(model):
    return {"name": model, "properties": {"model": {"name": model}}}


class CostTests(unittest.TestCase):
    def test_report_workflow_uses_supplied_client(self):
        # Return fixture pages and inventory without authenticating or calling Azure.
        subscription = "00000000-0000-0000-0000-000000000001"
        client = Mock()
        client.request.return_value = {"properties": {
            "columns": [{"name": name} for name in ("ResourceId", "Meter", "Currency", "Cost", "UsageQuantity")],
            "rows": [[ACCOUNT, "gpt-4o Input 1M Tokens", "USD", "0.1", "0.256217"]],
        }}
        client.list_resources.side_effect = [
            [{"id": ACCOUNT, "name": "ai", "kind": "AIServices"}],
            [deployment("gpt-4o")],
        ]
        report = get_cost_report(subscription, all_resources=True, client=client)
        self.assertEqual(report["subscription_id"], subscription)
        self.assertEqual(report["details"][0]["model"], "gpt-4o")
        self.assertEqual(report["details"][0]["tokens_consumed"], 256217)
        self.assertNotIn("filter", report["query"]["dataset"])

    def test_payload_filters_account_resources_with_daily_costs(self):
        payload = build_payload()
        self.assertEqual(payload["type"], "ActualCost")
        self.assertEqual(payload["dataset"]["granularity"], "Daily")
        self.assertEqual(payload["dataset"]["aggregation"]["totalCost"], {"name": "Cost", "function": "Sum"})
        self.assertEqual(payload["dataset"]["aggregation"]["totalUsage"], {"name": "UsageQuantity", "function": "Sum"})
        self.assertEqual(payload["dataset"]["filter"], {"dimensions": {
            "name": "ResourceType", "operator": "In", "values": ["microsoft.cognitiveservices/accounts"]
        }})
        self.assertEqual([item["name"] for item in payload["dataset"]["grouping"]], ["ResourceId", "Meter"])

    def test_all_resources_opt_in_omits_filter(self):
        self.assertNotIn("filter", build_payload(all_resources=True)["dataset"])

    def test_custom_dates_are_inclusive_and_validated(self):
        payload = build_payload(date(2026, 10, 1), date(2026, 10, 31))
        self.assertEqual(payload["timePeriod"]["to"], "2026-10-31T23:59:59+00:00")
        with self.assertRaises(ValueError):
            build_payload(date(2026, 10, 1))
        with self.assertRaises(ValueError):
            build_payload(date(2026, 10, 2), date(2026, 10, 1))

    def test_cost_pagination_reposts_payload_and_uses_column_names(self):
        # Continuation pages must reuse the query body and honor response column order.
        client = Mock()
        columns = [{"name": name} for name in ["Currency", "Meter", "Cost", "ResourceId", "UsageDate", "UsageQuantity"]]
        client.request.side_effect = [
            {"properties": {"columns": columns, "rows": [["USD", "input 1M Tokens", "0.1", ACCOUNT, 20261101, "0.1"]], "nextLink": "https://management.azure.com/next"}},
            {"properties": {"columns": columns, "rows": [["USD", "output 1M Tokens", "0.2", ACCOUNT, 20261102, "0.2"]]}},
        ]
        payload = build_payload()
        rows = query_costs(client, "sub", payload)
        self.assertEqual(sum(row["cost"] for row in rows), Decimal("0.3"))
        self.assertEqual(client.request.call_args.args, ("POST", "https://management.azure.com/next", payload))
        report = build_report("sub", payload, rows, [], {})
        self.assertEqual([row["usage_date"] for row in report["details"]], ["20261101", "20261102"])
        self.assertEqual(report["totals_scope"], "Filtered Cognitive Services accounts")
        self.assertEqual(report["subscription_totals"][0]["tokens_consumed"], 300000)

    def test_empty_and_malformed_billing_response(self):
        client = Mock()
        client.request.return_value = {}
        self.assertEqual(query_costs(client, "sub", build_payload()), [])
        client.request.return_value = {"properties": {"columns": [{"name": "cost"}], "rows": [[1]]}}
        with self.assertRaises(ValueError):
            query_costs(client, "sub", build_payload())

    def test_model_matching_does_not_confuse_prefixes_or_duplicate_deployments(self):
        models = [deployment("gpt-4"), deployment("gpt-4o"), deployment("gpt-4o-mini"), deployment("gpt-4o-mini")]
        self.assertEqual(infer_model("GPT-4o-mini Input Tokens", models), "gpt-4o-mini")
        self.assertIsNone(infer_model("gpt-4o input", [deployment("gpt-4")]))
        self.assertIsNone(infer_model("shared capacity", models))

    def test_model_matching_is_reused_per_account_and_meter(self):
        accounts = [{"id": ACCOUNT, "name": "ai", "deployments": [deployment("gpt-4o")]}]
        costs = [
            {"ResourceId": ACCOUNT, "Meter": meter, "Currency": "USD", "cost": Decimal("1")}
            for meter in ("gpt-4o Input", "gpt-4o Input", "shared", "shared")
        ]
        with patch("foundry_costs.infer_model", wraps=infer_model) as match:
            report = build_report("sub", build_payload(), costs, accounts, {})
        self.assertEqual(match.call_count, 2)
        self.assertEqual([row["model"] for row in report["details"]],
                         ["gpt-4o", "gpt-4o", "Unassigned model", "Unassigned model"])

    def test_model_match_cache_is_scoped_to_account(self):
        other_account = ACCOUNT + "-other"
        accounts = [
            {"id": ACCOUNT, "name": "ai", "deployments": [deployment("gpt-4o")]},
            {"id": other_account, "name": "other", "deployments": [deployment("gpt-4")]},
        ]
        costs = [
            {"ResourceId": account, "Meter": "gpt-4o Input", "Currency": "USD", "cost": Decimal("1")}
            for account in (ACCOUNT, other_account)
        ]
        report = build_report("sub", build_payload(), costs, accounts, {})
        self.assertEqual([row["model"] for row in report["details"]], ["gpt-4o", "Unassigned model"])

    def test_token_totals_preserve_zero_and_unavailable(self):
        def total(*counts):
            rows = [{"currency": "USD", "cost": Decimal("1"), "tokens_consumed": count}
                    for count in counts]
            return summarize(rows, ())[0]

        self.assertEqual(total(0)["tokens_consumed"], 0)
        self.assertIsNone(total(None)["tokens_consumed"])
        self.assertEqual(total(2, None, 3)["tokens_consumed"], 5)
        self.assertNotIn("token_coverage", total(0))

    def test_token_units_and_missing_data(self):
        for meter, quantity, expected in [
            ("5.4 mini Inp Gl 1M Tokens", "0.256217", 256217),
            ("gpt-4o Output 1K Tokens", "1.5", 1500),
            ("Input 1000 Tokens", "0.02", 20),
            ("Input 1,000 Tokens", "0.02", 20),
            ("Input 1 Tokens", "0", 0),
            ("Cached Input 1M Tokens", "-0.01", -10000),
        ]:
            with self.subTest(meter=meter):
                self.assertEqual(token_usage(meter, quantity), expected)
            self.assertIsNone(token_usage("Training Hours", "10"))
            self.assertIsNone(token_usage("Input Tokens", "10"))
            self.assertIsNone(token_usage("Input 1M Tokens", None))
            self.assertIsNone(token_usage("Input 1 Tokens", "0.5"))
            self.assertIsNone(token_usage("Capacity 1K Tokens per second", "10"))
            self.assertIsNone(token_usage("Input 1M Tokens", "invalid"))
            self.assertIsNone(token_usage("Input 1M Tokens", "NaN"))

    def test_report_sums_available_tokens_once(self):
        costs = [
            {"ResourceId": ACCOUNT, "Meter": "Input 1M Tokens", "Currency": "USD", "cost": Decimal("1"), "UsageQuantity": Decimal("0.256217")},
            {"ResourceId": ACCOUNT, "Meter": "Output 1K Tokens", "Currency": "USD", "cost": Decimal("2"), "UsageQuantity": Decimal("1.5")},
            {"ResourceId": ACCOUNT, "Meter": "Training Hours", "Currency": "USD", "cost": Decimal("3"), "UsageQuantity": Decimal("4")},
        ]
        report = build_report("sub", build_payload(), costs, [], {})
        self.assertEqual(report["subscription_totals"][0]["tokens_consumed"], 257717)
        self.assertEqual(report["model_totals"][0]["tokens_consumed"], 257717)
        self.assertNotIn("usage_quantity", report["details"][0])
        self.assertNotIn("token_status", report["details"][0])
        self.assertIsNone(report["details"][2]["tokens_consumed"])
        costs.append({"ResourceId": ACCOUNT, "Meter": "Input Tokens", "Currency": "USD", "cost": Decimal("5")})
        report = build_report("sub", build_payload(), costs, [], {})
        self.assertEqual(report["subscription_totals"][0]["cost"], "11")
        self.assertEqual(report["subscription_totals"][0]["tokens_consumed"], 257717)

    def test_conservation_credits_currency_and_mapping(self):
        costs = [
            {"ResourceId": ACCOUNT.upper(), "Meter": "gpt-4o Input", "Currency": "USD", "cost": Decimal("1.10")},
            {"ResourceId": ACCOUNT, "Meter": "shared", "Currency": "USD", "cost": Decimal("-0.10")},
            {"ResourceId": "/marketplace/model", "Meter": "input", "Currency": "USD", "cost": Decimal("2")},
            {"ResourceId": "", "Meter": "other", "Currency": "EUR", "cost": Decimal("3")},
        ]
        accounts = [{"id": ACCOUNT, "name": "ai", "deployments": [deployment("gpt-4o"), deployment("unused")]}]
        mapping = {"/marketplace/model": {"foundry_id": ACCOUNT, "meters": {"input": "partner-model"}}}
        report = build_report("sub", build_payload(all_resources=True), costs, accounts, mapping)
        self.assertEqual(report["totals_scope"], "All subscription resources")
        self.assertEqual({row["currency"]: row["cost"] for row in report["subscription_totals"]}, {"EUR": "3", "USD": "3.00"})
        self.assertEqual(len(report["details"]), 4)
        self.assertEqual(report["details"][0]["attribution"], "inferred_from_meter")
        self.assertEqual(report["details"][1]["model"], "Unassigned model")
        self.assertEqual(report["details"][2]["model"], "partner-model")
        self.assertNotIn("unused", [row["model"] for row in report["model_totals"]])
        for currency in ("USD", "EUR"):
            model_total = sum(Decimal(row["cost"]) for row in report["model_totals"] if row["currency"] == currency)
            subscription_total = next(Decimal(row["cost"]) for row in report["subscription_totals"] if row["currency"] == currency)
            self.assertEqual(model_total, subscription_total)

    def test_rejects_untrusted_pagination_url_before_requesting_token(self):
        credential = Mock()
        with self.assertRaises(ValueError):
            ArmClient(credential).request("GET", "https://example.com/next")
        credential.get_token.assert_not_called()

    def test_get_resource_pagination(self):
        client = ArmClient(Mock())
        with patch.object(client, "request", side_effect=[
            {"value": [{"id": "first"}], "nextLink": "next"},
            {"value": [{"id": "second"}]},
        ]):
            self.assertEqual(client.list_resources("first"), [{"id": "first"}, {"id": "second"}])


if __name__ == "__main__":
    unittest.main()