"""Report subscription billing by Foundry account and model/meter (Python 3.10+).

Cost Management supplies billed cost and usage quantities; the current account
inventory supplies model names for best-effort attribution. Token counts are
derived only from explicit units in meter names, so totals can be partial.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import sys
import time
from collections import defaultdict
from datetime import date, datetime, time as datetime_time, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlparse
from urllib.request import Request, urlopen
from uuid import UUID


# ARM hosts both the billing query and Cognitive Services inventory APIs.
ARM = "https://management.azure.com"
COST_VERSION = "2025-03-01"
ACCOUNT_VERSION = "2024-10-01"


class ArmClient:
    """Send authenticated ARM requests, preserving billing decimal precision."""

    def __init__(self, credential):
        self.credential = credential

    def request(self, method: str, url: str, payload: dict | None = None) -> dict:
        """Request a trusted ARM URL, retrying transient failures."""
        parsed = urlparse(url)
        # Pagination links come from responses; check the destination before sending a token.
        if parsed.scheme != "https" or parsed.netloc != "management.azure.com":
            raise ValueError("Refusing to send credentials outside Azure Resource Manager.")
        body = json.dumps(payload).encode() if payload is not None else None
        for attempt in range(5):
            token = self.credential.get_token(f"{ARM}/.default").token
            request = Request(url, data=body, method=method, headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
            })
            try:
                with urlopen(request, timeout=90) as response:
                    content = response.read()
                    # Preserve monetary and usage precision from the JSON response.
                    return json.loads(content, parse_float=Decimal) if content else {}
            except HTTPError as error:
                # Retry throttling and transient server errors, but bound the wait time.
                if error.code in {429, 500, 502, 503, 504} and attempt < 4:
                    retry = error.headers.get(
                        "x-ms-ratelimit-microsoft.consumption-retry-after",
                        error.headers.get("Retry-After", ""),
                    )
                    delay = float(retry) if retry.isdigit() else 2 ** attempt
                    if delay > 120:
                        raise RuntimeError(f"Azure throttled the query; retry after {retry} seconds.") from error
                    time.sleep(delay)
                    continue
                detail = error.read().decode("utf-8", errors="replace")
                raise RuntimeError(f"ARM HTTP {error.code}: {detail}") from error
        raise RuntimeError("ARM retry limit exceeded.")

    def list_resources(self, url: str) -> list[dict]:
        """Read all pages of an ARM resource-list response."""
        resources = []
        while url:
            page = self.request("GET", url)
            resources.extend(page.get("value", []))
            url = page.get("nextLink")
        return resources


def build_payload(start: date | None = None, end: date | None = None, *, all_resources: bool = False) -> dict:
    """Build a daily billing query; custom UTC dates are inclusive."""
    if bool(start) != bool(end):
        raise ValueError("Supply both --start and --end.")
    if start and end and start > end:
        raise ValueError("--start must not be after --end.")
    payload = {
        "type": "ActualCost",
        "timeframe": "MonthToDate",
        "dataset": {
            "granularity": "Daily",
            "aggregation": {
                "totalCost": {"name": "Cost", "function": "Sum"},
                "totalUsage": {"name": "UsageQuantity", "function": "Sum"},
            },
            "grouping": [
                {"type": "Dimension", "name": "ResourceId"},
                {"type": "Dimension", "name": "Meter"},
            ],
        },
    }
    # The default covers Cognitive Services accounts, not every subscription charge.
    if not all_resources:
        payload["dataset"]["filter"] = {
            "dimensions": {
                "name": "ResourceType",
                "operator": "In",
                "values": ["microsoft.cognitiveservices/accounts"],
            }
        }
    if start and end:
        payload["timeframe"] = "Custom"
        payload["timePeriod"] = {
            "from": datetime.combine(start, datetime_time.min, timezone.utc).isoformat(),
            "to": datetime.combine(end, datetime_time(23, 59, 59), timezone.utc).isoformat(),
        }
    return payload


def query_costs(client: ArmClient, subscription: str, payload: dict) -> list[dict]:
    """Fetch every billing page, preserving decimal amounts and currency."""
    url = f"{ARM}/subscriptions/{subscription}/providers/Microsoft.CostManagement/query?api-version={COST_VERSION}"
    rows = []
    while url:
        # Continuation pages use POST with the original query body.
        page = client.request("POST", url, payload)
        properties = page.get("properties", {})
        # Cost Management returns positional rows; column order can vary between queries.
        columns = [column["name"] for column in properties.get("columns", [])]
        if properties.get("rows") and not {"ResourceId", "Meter", "Currency"}.issubset(columns):
            raise ValueError(f"Unexpected billing columns: {columns}")
        for values in properties.get("rows", []):
            if len(values) != len(columns):
                raise ValueError("Billing row length does not match columns.")
            row = dict(zip(columns, values))
            cost_column = next((name for name in ("PreTaxCost", "Cost", "totalCost") if name in row), None)
            if cost_column is None or row[cost_column] is None or not row["Currency"]:
                raise ValueError("Billing row is missing its cost or currency.")
            row["cost"] = Decimal(str(row[cost_column]))
            rows.append(row)
        url = properties.get("nextLink")
    return rows


def discover_accounts(client: ArmClient, subscription: str) -> list[dict]:
    """Return current AI Services/OpenAI accounts and their deployments."""
    url = f"{ARM}/subscriptions/{subscription}/providers/Microsoft.CognitiveServices/accounts?api-version={ACCOUNT_VERSION}"
    accounts = []
    for account in client.list_resources(url):
        if account.get("kind", "").lower() not in {"aiservices", "openai"}:
            continue
        account["deployments"] = client.list_resources(
            f"{ARM}{account['id']}/deployments?api-version={ACCOUNT_VERSION}"
        )
        accounts.append(account)
    return accounts


def resource_key(resource_id: str) -> str:
    """Normalize ARM IDs for case-insensitive inventory and mapping lookups."""
    return resource_id.rstrip("/").lower()


def normalize_label(label: str) -> str:
    """Normalize punctuation and case before matching model names in meters."""
    return re.sub(r"[^a-z0-9]+", " ", label.lower()).strip()


def infer_model(meter: str, deployments: list[dict]) -> str | None:
    """Match the most specific unambiguous deployed model in a meter name."""
    label = f" {normalize_label(meter)} "
    candidates = {
        deployment.get("properties", {}).get("model", {}).get("name", "")
        for deployment in deployments
    }
    normalized = {model: normalize_label(model) for model in candidates if model}
    matches = [model for model, name in normalized.items() if f" {name} " in label]
    # Prefer the longer name when one model is embedded in another, such as
    # gpt-4o within gpt-4o-mini; unrelated multiple matches remain ambiguous.
    longest = [model for model in matches if not any(
        normalized[model] != normalized[other]
        and f" {normalized[model]} " in f" {normalized[other]} "
        for other in matches
    )]
    return longest[0] if len(longest) == 1 else None


def load_mapping(path: Path | None) -> dict:
    """Read exact resource and meter mappings, validating their structure."""
    if path is None:
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError("Mapping must be an object keyed by billing resource ID.")
    result = {}
    for resource_id, entry in data.items():
        if not isinstance(entry, dict) or not isinstance(entry.get("foundry_id"), str):
            raise ValueError("Each mapping needs a foundry_id and a meters object.")
        meters = entry.get("meters")
        if not isinstance(meters, dict) or not all(
            isinstance(meter, str) and isinstance(model, str) and model.strip()
            for meter, model in meters.items()
        ):
            raise ValueError("Mapping meters must map exact meter names to nonempty model names.")
        # Resource IDs are case-insensitive; meter keys remain exact and case-sensitive.
        result[resource_key(resource_id)] = entry
    return result


def summarize(rows: list[dict], dimensions: tuple[str, ...]) -> list[dict]:
    """Sum costs by dimensions and currency; unavailable tokens remain null."""
    totals = defaultdict(Decimal)
    tokens = defaultdict(int)
    for row in rows:
        # Never combine costs from different currencies, even for subscription totals.
        key = tuple(row[dimension] for dimension in dimensions) + (row["currency"],)
        totals[key] += row["cost"]
        if row.get("tokens_consumed") is not None:
            tokens[key] += row["tokens_consumed"]
    result = []
    for key, cost in sorted(totals.items()):
        result.append(dict(
            zip((*dimensions, "currency"), key),
            cost=str(cost),
            # Missing means no convertible token rows; zero remains a valid total.
            tokens_consumed=tokens.get(key),
        ))
    return result


def token_usage(meter: str, quantity) -> int | None:
    """Convert explicitly labeled billed units to whole tokens, or return None."""
    if not re.search(r"\btokens?\b", meter, re.IGNORECASE):
        return None
    # Require a terminal unit such as "1M Tokens"; a token rate is not a count.
    unit = re.search(r"(?<![\w.,])(\d+(?:,\d{3})*(?:\.\d+)?)\s*([KMB]?)\s+tokens?\s*$", meter, re.IGNORECASE)
    if unit is None or quantity is None:
        return None
    multiplier = {"": 1, "K": 1000, "M": 1000000, "B": 1000000000}[unit.group(2).upper()]
    try:
        count = Decimal(str(quantity)) * Decimal(unit.group(1).replace(",", "")) * multiplier
    except InvalidOperation:
        return None
    # Do not round fractional or invalid results into misleading token counts.
    if not count.is_finite() or count != count.to_integral_value():
        return None
    return int(count)


def build_report(subscription: str, payload: dict, costs: list[dict], accounts: list[dict], mapping: dict) -> dict:
    """Attribute billing rows conservatively and return report data and warnings."""
    inventory = {resource_key(account["id"]): account for account in accounts}
    details = []
    model_matches = {}
    for row in costs:
        resource_id = row.get("ResourceId") or ""
        key = resource_key(resource_id)
        # Deployment and project resource IDs are attributed to their parent account.
        account_key = key.split("/deployments/")[0].split("/projects/")[0]
        entry = mapping.get(key, {})
        foundry_id = entry.get("foundry_id", inventory.get(account_key, {}).get("id", ""))
        if not foundry_id and "/providers/microsoft.cognitiveservices/accounts/" in key:
            foundry_id = resource_id[:len(account_key)]
        account = inventory.get(resource_key(foundry_id), {})
        meter = row.get("Meter") or ""
        quantity = row.get("UsageQuantity", row.get("totalUsage"))
        tokens_consumed = token_usage(meter, quantity)
        # An exact mapping wins; otherwise infer only from the current inventory.
        model = entry.get("meters", {}).get(meter)
        attribution = "explicit_mapping" if model else "unassigned"
        if not model and account:
            match_key = (resource_key(foundry_id), meter)
            # A meter can recur across daily rows, so reuse its account-specific match.
            if match_key not in model_matches:
                model_matches[match_key] = infer_model(meter, account["deployments"])
            model = model_matches[match_key]
            if model:
                attribution = "inferred_from_meter"
        details.append({
            "foundry_id": foundry_id,
            "foundry": foundry_id.rsplit("/", 1)[-1] if foundry_id else "Unassigned subscription charges",
            "resource_id": resource_id,
            "model": model or "Unassigned model",
            "meter": meter,
            "usage_date": str(row.get("UsageDate") or ""),
            "tokens_consumed": tokens_consumed,
            "attribution": attribution,
            "currency": row["Currency"],
            "cost": row["cost"],
        })
    # Keep unmatched rows and warnings in the report rather than dropping charges.
    return {
        "subscription_id": subscription,
        "query": payload,
        "totals_scope": "Filtered Cognitive Services accounts" if "filter" in payload["dataset"] else "All subscription resources",
        "warnings": [
            "Model matches inferred from meter names are not authoritative billing attribution.",
            "Current deployments do not describe deleted or historical models; use exact meter mappings.",
            "Foundry means the billing AI Services/OpenAI account, not an individual project or classic hub.",
            "Totals cover only queried resource types. The default filter excludes Marketplace and shared infrastructure, and can include non-Foundry Cognitive Services accounts.",
            "Billing data can be delayed. No billing row does not establish zero usage or zero cost.",
            "Tokens are net billed usage calculated from meter labels, not Azure Monitor measurements. Totals may be partial when token units or quantities are unavailable.",
        ],
        "subscription_totals": summarize(details, ()),
        "foundry_totals": summarize(details, ("foundry_id", "foundry")),
        "model_totals": summarize(details, ("foundry_id", "foundry", "model", "attribution")),
        "details": [{**row, "cost": str(row["cost"])} for row in details],
        "inventory": [{
            "foundry_id": account["id"],
            "foundry": account["name"],
            "deployments": [{
                "name": deployment["name"],
                "model": deployment.get("properties", {}).get("model", {}),
            } for deployment in account["deployments"]],
        } for account in accounts],
    }


def get_cost_report(
    subscription: str,
    start: date | None = None,
    end: date | None = None,
    *,
    mapping_path: Path | None = None,
    all_resources: bool = False,
    client: ArmClient | None = None,
) -> dict:
    """Return a complete report without printing or writing files.

    Dates are inclusive UTC dates. Unless a client is provided, authentication
    uses DefaultAzureCredential. Billed token totals can be partial, and inferred
    model attribution is not authoritative. Errors propagate to the caller.
    """
    subscription = str(UUID(subscription))
    payload = build_payload(start, end, all_resources=all_resources)
    mapping = load_mapping(mapping_path)

    def collect(arm_client: ArmClient) -> dict:
        costs = query_costs(arm_client, subscription, payload)
        accounts = discover_accounts(arm_client, subscription)
        return build_report(subscription, payload, costs, accounts, mapping)

    # A supplied client remains owned by the caller; close only credentials created here.
    if client is not None:
        return collect(client)
    from azure.identity import DefaultAzureCredential

    with DefaultAzureCredential(exclude_interactive_browser_credential=True) as credential:
        return collect(ArmClient(credential))


def main(argv: list[str] | None = None) -> int:
    """Run the command-line workflow and optionally export the resulting report."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--subscription-id", default=os.getenv("AZURE_SUBSCRIPTION_ID"))
    parser.add_argument("--start", type=date.fromisoformat, help="UTC date YYYY-MM-DD")
    parser.add_argument("--end", type=date.fromisoformat, help="Inclusive UTC date YYYY-MM-DD")
    parser.add_argument("--mapping", type=Path, help="Exact billing resource/meter mappings as JSON")
    parser.add_argument("--all-resources", action="store_true", help="Include all subscription resource types instead of only Cognitive Services accounts")
    parser.add_argument("--json", type=Path, dest="json_path")
    parser.add_argument("--csv", type=Path, dest="csv_path")
    parser.add_argument("--print-payload", action="store_true", help="Print the POST body without authenticating")
    args = parser.parse_args(argv)
    try:
        payload = build_payload(args.start, args.end, all_resources=args.all_resources)
        # Payload inspection does not require credentials or network access.
        if args.print_payload:
            print(json.dumps(payload, indent=2))
            return 0
        if not args.subscription_id:
            parser.error("--subscription-id or AZURE_SUBSCRIPTION_ID is required")
        report = get_cost_report(args.subscription_id, args.start, args.end, mapping_path=args.mapping, all_resources=args.all_resources)
        subscription = report["subscription_id"]
        print(f"Subscription: {subscription}")
        print(f"Cost scope: {report['totals_scope']}")
        for total in report["subscription_totals"]:
            print(f"Queried resource total: {total['cost']} {total['currency']}")
        for total in report["foundry_totals"]:
            print(f"Foundry total: {total['foundry']} | {total['cost']} {total['currency']} | {total['foundry_id']}")
        print("\nFoundry | Model | Attribution | Cost | Currency | Tokens Consumed | Foundry ID")
        for row in report["model_totals"]:
            print(" | ".join(str(row[field]) if row[field] is not None else "N/A" for field in (
                "foundry", "model", "attribution", "cost", "currency", "tokens_consumed", "foundry_id"
            )))
        if not report["details"]:
            print("No billing rows returned for this period.")
        for account in report["inventory"]:
            models = sorted({item["model"].get("name", "Unknown") for item in account["deployments"]})
            print(f"Inventory: {account['foundry']} | {', '.join(models) or 'No deployments'}")
        for warning in report["warnings"]:
            print(f"Warning: {warning}", file=sys.stderr)
        if args.json_path:
            args.json_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
        if args.csv_path:
            with args.csv_path.open("w", newline="", encoding="utf-8") as output:
                fields = ["foundry_id", "foundry", "resource_id", "model", "meter", "usage_date", "attribution", "currency", "cost", "tokens_consumed"]
                writer = csv.DictWriter(output, fieldnames=fields)
                writer.writeheader()
                writer.writerows(report["details"])
        return 0
    except (ValueError, RuntimeError, OSError, ImportError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())