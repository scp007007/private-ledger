"""FastAPI service for a personal, self-hosted ledger."""

from __future__ import annotations

import csv
import hashlib
import hmac
import io
import json
import os
import re
import sqlite3
import uuid
from collections import defaultdict
from contextlib import asynccontextmanager, closing
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Any, Literal

from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, Query, UploadFile
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel, ConfigDict, Field, StrictBool, model_validator

from .db import (
    IMPORT_PREVIEW_TTL, connect, current_revision, initialize, ledger_id,
    next_revision, prune_import_previews, settings, transaction_dict,
)
from .importers import BillImportError, parse_bill
from .rules import RuleError, apply_rules_with_metadata, validate_rule


MAX_IMPORT_BYTES = 10 * 1024 * 1024
EDITABLE_FIELDS = {"category", "tags", "note", "excluded", "refund_of_id", "amount_cents", "direction", "merchant", "description", "occurred_at"}


def _valid_api_token(value: str | None) -> bool:
    # Tokens travel in an HTTP header and are compared as ASCII strings. Keep
    # configuration and incoming credentials within the same explicit bounds.
    return isinstance(value, str) and re.fullmatch(r"[\x21-\x7e]{24,1024}", value) is not None


class EditChanges(BaseModel):
    model_config = ConfigDict(extra="forbid")

    category: str | None = Field(default=None, max_length=200)
    tags: list[str] = Field(default_factory=list, max_length=50)
    note: str = Field(default="", max_length=4000)
    excluded: StrictBool | None = None
    refund_of_id: uuid.UUID | None = None
    amount_cents: int | None = Field(default=None, strict=True, gt=0, le=9007199254740991)
    direction: Literal["expense", "income"] | None = None
    merchant: str | None = Field(default=None, max_length=500)
    description: str | None = Field(default=None, max_length=2000)
    occurred_at: datetime | None = None


class ManualCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")
    operation_id: uuid.UUID
    transaction_id: uuid.UUID
    amount_cents: int = Field(strict=True, gt=0, le=9007199254740991)
    direction: Literal["expense", "income"]
    occurred_at: datetime
    merchant: str = Field(default="", max_length=500)
    description: str = Field(default="", max_length=2000)
    category: str | None = Field(default=None, max_length=200)
    tags: list[str] = Field(default_factory=list, max_length=50)
    note: str = Field(default="", max_length=4000)
    excluded: StrictBool = False


def _accounting_time(value: datetime) -> str:
    if value.tzinfo is None:
        raise HTTPException(status_code=422, detail="Transaction time requires a timezone offset")
    return value.astimezone(timezone(timedelta(hours=8))).isoformat(timespec="seconds")


class EditRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    operation_id: uuid.UUID
    transaction_id: uuid.UUID
    expected_version: int = Field(ge=1)
    changes: EditChanges


class SettingsPatch(BaseModel):
    model_config = ConfigDict(extra="forbid")

    exclude_red_packets: StrictBool


class RuleConditions(BaseModel):
    model_config = ConfigDict(extra="forbid")

    source: Literal["alipay", "wechat", "generic"] | None = None
    kind: Literal["payment", "refund", "transfer", "red_packet", "other"] | None = None
    direction: Literal["expense", "income"] | None = None
    merchant_contains: str | None = Field(default=None, max_length=200)
    description_contains: str | None = Field(default=None, max_length=200)

    @model_validator(mode="after")
    def at_least_one_condition(self):
        values = self.model_dump(exclude_none=True)
        if not values or any(isinstance(value, str) and not value.strip() for value in values.values()):
            raise ValueError("A rule needs at least one non-empty condition")
        return self


class RuleActions(BaseModel):
    model_config = ConfigDict(extra="forbid")

    category: str | None = Field(default=None, max_length=200)
    tags: list[str] | None = Field(default=None, max_length=50)
    excluded: StrictBool | None = None

    @model_validator(mode="after")
    def at_least_one_action(self):
        values = self.model_dump(exclude_none=True)
        if not values or ("category" in values and not values["category"].strip()):
            raise ValueError("A rule needs at least one non-empty action")
        return self


class RuleCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    enabled: StrictBool = True
    priority: int = Field(default=100, ge=-10000, le=10000)
    conditions: RuleConditions
    actions: RuleActions


def _load_rules(connection: sqlite3.Connection) -> list[dict[str, Any]]:
    rows = connection.execute("SELECT * FROM rules ORDER BY priority, id").fetchall()
    return [
        {
            "id": row["id"],
            "enabled": bool(row["enabled"]),
            "priority": row["priority"],
            "conditions": json.loads(row["conditions_json"]),
            "actions": json.loads(row["actions_json"]),
        }
        for row in rows
    ]


def _month_key(year: int, month: int) -> str:
    return f"{year:04d}-{month:02d}"


def _safe_csv_text(value: str) -> str:
    # Excel and other spreadsheet apps can execute user-controlled CSV cells.
    if value.startswith(("\t", "\r", "\n")) or value.lstrip().startswith(("=", "+", "-", "@")):
        return "'" + value
    return value


def _prepare_import_row(
    row: dict[str, Any], exclude_red_packets: bool, rules: list[dict[str, Any]]
) -> dict[str, Any]:
    prepared = dict(row)
    closed = row.get("exclusion_reason") == "closed_or_failed"
    if row["kind"] == "red_packet" and not closed:
        prepared["excluded"] = exclude_red_packets
        prepared["exclusion_reason"] = "default_red_packet" if exclude_red_packets else None
    elif row["kind"] == "transfer" and not row.get("excluded", False):
        prepared["excluded"] = True
        prepared["exclusion_reason"] = "default_transfer"

    prepared, applied_by_field = apply_rules_with_metadata(prepared, rules)
    if closed:
        prepared["excluded"] = True
        prepared["exclusion_reason"] = "closed_or_failed"
        prepared["_excluded_override"] = 1
    elif "excluded" in applied_by_field:
        prepared["exclusion_reason"] = (
            f"rule:{applied_by_field['excluded']}" if prepared["excluded"] else None
        )
        prepared["_excluded_override"] = int(prepared["excluded"])
    else:
        prepared["_excluded_override"] = None
    return prepared


def _preview_row(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": str(uuid.uuid5(uuid.NAMESPACE_URL, "ledger:" + row["dedupe_key"])),
        "source": row["source"],
        "external_id": row.get("external_id"),
        "occurred_at": row["occurred_at"],
        "amount_cents": row["amount_cents"],
        "direction": row["direction"],
        "kind": row["kind"],
        "merchant": row.get("merchant", ""),
        "description": row.get("description", ""),
        "category": row.get("category"),
        "tags": row.get("tags", []),
        "note": row.get("note", ""),
        "excluded": row.get("excluded", False),
        "exclusion_reason": row.get("exclusion_reason"),
        "refund_of_id": row.get("refund_of_id"),
    }


def _build_report(connection: sqlite3.Connection, year: int, month: int) -> dict[str, Any]:
    all_rows = connection.execute("SELECT * FROM transactions").fetchall()
    by_id = {row["id"]: row for row in all_rows}
    target = _month_key(year, month)
    category_totals: dict[str, int] = defaultdict(int)
    gross_cents = 0
    applied_refunds_cents = 0
    over_refund_cents = 0
    income_cents = 0
    unlinked_refunds_cents = 0
    unlinked_refunds_count = 0
    refunds_by_original: dict[str, int] = defaultdict(int)

    for row in all_rows:
        in_month = row["occurred_at"][:7] == target
        if row["excluded"]:
            continue

        if row["kind"] == "refund" and row["direction"] == "income":
            original = by_id.get(row["refund_of_id"])
            if original is None:
                if in_month:
                    unlinked_refunds_cents += row["amount_cents"]
                    unlinked_refunds_count += 1
            else:
                refunds_by_original[original["id"]] += row["amount_cents"]
            continue

        if not in_month:
            continue
        if row["direction"] == "expense":
            category_totals[row["category"] or "未分类"] += row["amount_cents"]
            gross_cents += row["amount_cents"]
        else:
            income_cents += row["amount_cents"]

    for original_id, total_refunded in refunds_by_original.items():
        original = by_id[original_id]
        if original["occurred_at"][:7] != target or original["excluded"]:
            continue
        applied = min(total_refunded, original["amount_cents"])
        category_totals[original["category"] or "未分类"] -= applied
        applied_refunds_cents += applied
        over_refund_cents += total_refunded - applied

    return {
        "year": year,
        "month": month,
        "revision": current_revision(connection),
        "total_actual_consumption_cents": gross_cents - applied_refunds_cents,
        "gross_consumption_cents": gross_cents,
        "applied_refunds_cents": applied_refunds_cents,
        "over_refund_cents": over_refund_cents,
        "total_income_cents": income_cents,
        "unlinked_refunds_cents": unlinked_refunds_cents,
        "unlinked_refunds_count": unlinked_refunds_count,
        "category_totals": [
            {"category": name, "amount_cents": amount}
            for name, amount in sorted(category_totals.items(), key=lambda item: (-item[1], item[0]))
        ],
    }


def create_app(database_path: str | Path | None = None, api_token: str | None = None) -> FastAPI:
    path = Path(database_path or os.environ.get("LEDGER_DB_PATH", "data/ledger.sqlite3"))
    token = api_token if api_token is not None else os.environ.get("LEDGER_API_TOKEN")

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        if not _valid_api_token(token):
            raise RuntimeError(
                "Set LEDGER_API_TOKEN to 24 to 1024 printable ASCII characters without spaces"
            )
        initialize(path)
        yield

    app = FastAPI(title="Personal Ledger API", version="0.1.0", lifespan=lifespan)
    app.state.db_path = path

    @app.middleware("http")
    async def prevent_private_response_caching(request, call_next):
        response = await call_next(request)
        if request.url.path.startswith("/api/"):
            response.headers["Cache-Control"] = "no-store"
            response.headers["Pragma"] = "no-cache"
        return response

    @app.exception_handler(RequestValidationError)
    async def private_validation_error(request, exc):
        # FastAPI normally returns the offending input (including nested
        # objects). Even unknown JSON property names may hold private text.
        known_fields = {
            "body", "query", "path", "header", "source", "file", "column_mapping",
            "preview_id", "rule_id", "since", "year", "month", "redact", "authorization",
        }
        for model in (EditChanges, EditRequest, ManualCreate, SettingsPatch, RuleConditions, RuleActions, RuleCreate):
            known_fields.update(model.model_fields)
        return JSONResponse(status_code=422, content={"detail": [
            {
                "loc": [part if isinstance(part, int) or part in known_fields else "field"
                        for part in error["loc"]],
                "msg": "Invalid request value",
                "type": error["type"],
            }
            for error in exc.errors()
        ]})

    def authorize(authorization: str | None = Header(default=None)) -> None:
        if not authorization or not authorization.startswith("Bearer "):
            raise HTTPException(status_code=401, detail="Bearer token required", headers={"WWW-Authenticate": "Bearer"})
        supplied = authorization.removeprefix("Bearer ")
        if not _valid_api_token(supplied) or token is None or not hmac.compare_digest(supplied, token):
            raise HTTPException(status_code=401, detail="Invalid token", headers={"WWW-Authenticate": "Bearer"})

    @app.get("/health")
    def health() -> dict[str, str]:
        return {"status": "ok", "service": "private-ledger"}

    @app.get("/api/v1/sync", dependencies=[Depends(authorize)])
    def sync(since: int = Query(default=0, ge=0)) -> dict[str, Any]:
        with closing(connect(path)) as connection:
            connection.execute("BEGIN")
            revision = current_revision(connection)
            rows = connection.execute(
                "SELECT * FROM transactions WHERE revision > ? AND revision <= ? ORDER BY revision, id",
                (since, revision),
            ).fetchall()
            result = {
                "ledger_id": ledger_id(connection),
                "revision": revision,
                "transactions": [transaction_dict(row) for row in rows],
                "settings": settings(connection),
                "rules": _load_rules(connection),
            }
            connection.commit()
            return result

    @app.get("/api/v1/settings", dependencies=[Depends(authorize)])
    def get_settings() -> dict[str, Any]:
        with closing(connect(path)) as connection:
            return {"settings": settings(connection), "revision": current_revision(connection)}

    @app.get("/api/v1/rules", dependencies=[Depends(authorize)])
    def get_rules() -> dict[str, Any]:
        with closing(connect(path)) as connection:
            return {"rules": _load_rules(connection), "revision": current_revision(connection)}

    @app.post("/api/v1/rules", dependencies=[Depends(authorize)])
    def create_rule(request: RuleCreate) -> dict[str, Any]:
        rule_id = str(uuid.uuid4())
        conditions = request.conditions.model_dump(exclude_none=True)
        actions = request.actions.model_dump(exclude_none=True)
        rule = {
            "id": rule_id, "enabled": request.enabled, "priority": request.priority,
            "conditions": conditions, "actions": actions,
        }
        try:
            validate_rule(rule)
        except RuleError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
        with closing(connect(path)) as connection:
            connection.execute("BEGIN IMMEDIATE")
            revision = next_revision(connection)
            connection.execute(
                "INSERT INTO rules (id, enabled, priority, conditions_json, actions_json, created_at) "
                "VALUES (?, ?, ?, ?, ?, ?)",
                (
                    rule_id, int(request.enabled), request.priority,
                    json.dumps(conditions, ensure_ascii=False), json.dumps(actions, ensure_ascii=False),
                    datetime.now(timezone.utc).isoformat(),
                ),
            )
            result = {"rule": rule, "revision": revision}
            connection.commit()
            return result

    @app.delete("/api/v1/rules/{rule_id}", dependencies=[Depends(authorize)])
    def delete_rule(rule_id: uuid.UUID) -> dict[str, Any]:
        with closing(connect(path)) as connection:
            connection.execute("BEGIN IMMEDIATE")
            removed = connection.execute("DELETE FROM rules WHERE id = ?", (str(rule_id),))
            if removed.rowcount == 0:
                connection.rollback()
                raise HTTPException(status_code=404, detail="Rule not found")
            revision = next_revision(connection)
            connection.commit()
            return {"deleted": True, "revision": revision}

    @app.patch("/api/v1/settings", dependencies=[Depends(authorize)])
    def patch_settings(request: SettingsPatch) -> dict[str, Any]:
        with closing(connect(path)) as connection:
            connection.execute("BEGIN IMMEDIATE")
            old = settings(connection)["exclude_red_packets"]
            new = request.exclude_red_packets
            if old != new:
                connection.execute("UPDATE ledger_meta SET exclude_red_packets = ? WHERE id = 1", (int(new),))
                next_revision(connection)  # The settings change itself is a sync event.
                changed = connection.execute(
                    "SELECT id FROM transactions WHERE kind = 'red_packet' AND excluded_override IS NULL"
                ).fetchall()
                for row in changed:
                    revision = next_revision(connection)
                    connection.execute(
                        "UPDATE transactions SET excluded = ?, exclusion_reason = ?, "
                        "version = version + 1, revision = ? WHERE id = ?",
                        (int(new), "default_red_packet" if new else None, revision, row["id"]),
                    )
            result = {"settings": settings(connection), "revision": current_revision(connection)}
            connection.commit()
            return result

    @app.post("/api/v1/transactions", dependencies=[Depends(authorize)])
    def create_manual_transaction(request: ManualCreate) -> Any:
        occurred_at = _accounting_time(request.occurred_at)
        digest = hashlib.sha256(json.dumps({"create": request.model_dump(mode="json")}, sort_keys=True).encode()).hexdigest()
        with closing(connect(path)) as connection:
            connection.execute("BEGIN IMMEDIATE")
            previous = connection.execute("SELECT * FROM edit_operations WHERE operation_id = ?", (str(request.operation_id),)).fetchone()
            if previous:
                if previous["request_hash"] != digest:
                    raise HTTPException(status_code=409, detail="operation_id already used")
                return json.loads(previous["response_json"])
            if connection.execute("SELECT id FROM transactions WHERE id = ?", (str(request.transaction_id),)).fetchone():
                raise HTTPException(status_code=409, detail="Transaction ID already exists")
            revision = next_revision(connection)
            connection.execute(
                "INSERT INTO transactions (id, source, dedupe_key, occurred_at, amount_cents, direction, kind, merchant, description, category, tags_json, note, excluded, excluded_override, exclusion_reason, raw_json, revision) "
                "VALUES (?, 'manual', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '{}', ?)",
                (str(request.transaction_id), 'manual:' + str(request.transaction_id), occurred_at,
                 request.amount_cents, request.direction, 'payment' if request.direction == 'expense' else 'other',
                 request.merchant, request.description, request.category, json.dumps(request.tags, ensure_ascii=False),
                 request.note, int(request.excluded), int(request.excluded), 'manual' if request.excluded else None, revision),
            )
            row = connection.execute("SELECT * FROM transactions WHERE id = ?", (str(request.transaction_id),)).fetchone()
            result = {"transaction": transaction_dict(row), "revision": revision}
            connection.execute("INSERT INTO edit_operations VALUES (?, ?, ?)", (str(request.operation_id), digest, json.dumps(result, ensure_ascii=False)))
            connection.commit()
            return result

    @app.post("/api/v1/edits", dependencies=[Depends(authorize)])
    def edit_transaction(request: EditRequest) -> Any:
        changes = request.changes.model_dump(exclude_unset=True, mode="json")
        if not changes:
            raise HTTPException(status_code=422, detail="At least one change is required")
        if "excluded" in changes and changes["excluded"] is None:
            raise HTTPException(status_code=422, detail="excluded must be true or false")
        if any(key in changes and changes[key] is None for key in ("amount_cents", "direction", "merchant", "description", "occurred_at")):
            raise HTTPException(status_code=422, detail="Accounting fields cannot be null")
        if "occurred_at" in changes:
            changes["occurred_at"] = _accounting_time(request.changes.occurred_at)
        request_hash = hashlib.sha256(
            json.dumps(request.model_dump(mode="json"), sort_keys=True, ensure_ascii=False).encode("utf-8")
        ).hexdigest()

        with closing(connect(path)) as connection:
            connection.execute("BEGIN IMMEDIATE")
            previous = connection.execute(
                "SELECT request_hash, response_json FROM edit_operations WHERE operation_id = ?",
                (str(request.operation_id),),
            ).fetchone()
            if previous is not None:
                if previous["request_hash"] != request_hash:
                    connection.rollback()
                    raise HTTPException(status_code=409, detail="operation_id already used for a different edit")
                result = json.loads(previous["response_json"])
                connection.commit()
                return result

            row = connection.execute("SELECT * FROM transactions WHERE id = ?", (str(request.transaction_id),)).fetchone()
            if row is None:
                connection.rollback()
                raise HTTPException(status_code=404, detail="Transaction not found")
            if row["version"] != request.expected_version:
                current = transaction_dict(row)
                connection.rollback()
                return JSONResponse(status_code=409, content={"detail": "conflict", "current": current})

            new_direction = changes.get("direction", row["direction"])
            new_refund = changes.get("refund_of_id", row["refund_of_id"])
            if new_refund and (row["kind"] != "refund" or new_direction != "income"):
                raise HTTPException(status_code=422, detail="Linked refunds must remain incoming refunds")
            if new_direction != "expense" and connection.execute("SELECT id FROM transactions WHERE refund_of_id = ?", (row["id"],)).fetchone():
                raise HTTPException(status_code=422, detail="A purchase with linked refunds must remain an expense")

            if "refund_of_id" in changes and changes["refund_of_id"] is not None:
                if row["kind"] != "refund" or row["direction"] != "income":
                    connection.rollback()
                    raise HTTPException(status_code=422, detail="Only an incoming refund can link to a purchase")
                original = connection.execute(
                    "SELECT id, direction, kind FROM transactions WHERE id = ?", (changes["refund_of_id"],)
                ).fetchone()
                if original is None or original["direction"] != "expense" or original["kind"] not in ("payment", "other"):
                    connection.rollback()
                    raise HTTPException(status_code=422, detail="refund_of_id must reference an expense purchase")

            assignments: list[str] = []
            values: list[Any] = []
            for key, value in changes.items():
                if key not in EDITABLE_FIELDS:
                    continue
                if key == "tags":
                    assignments.append("tags_json = ?")
                    values.append(json.dumps(value, ensure_ascii=False))
                elif key == "excluded":
                    assignments.extend(("excluded = ?", "excluded_override = ?", "exclusion_reason = ?"))
                    values.extend((int(value), int(value), "manual" if value else None))
                else:
                    assignments.append(f"{key} = ?")
                    values.append(value)

            revision = next_revision(connection)
            assignments.extend(("version = version + 1", "revision = ?"))
            values.extend((revision, str(request.transaction_id)))
            connection.execute(f"UPDATE transactions SET {', '.join(assignments)} WHERE id = ?", values)
            updated = connection.execute("SELECT * FROM transactions WHERE id = ?", (str(request.transaction_id),)).fetchone()
            result = {"transaction": transaction_dict(updated), "revision": revision}
            connection.execute(
                "INSERT INTO edit_operations (operation_id, request_hash, response_json) VALUES (?, ?, ?)",
                (str(request.operation_id), request_hash, json.dumps(result, ensure_ascii=False)),
            )
            connection.commit()
            return result

    @app.post("/api/v1/imports/preview", dependencies=[Depends(authorize)])
    async def preview_import(
        source: str = Form(...),
        file: UploadFile = File(...),
        column_mapping: str | None = Form(default=None),
    ) -> dict[str, Any]:
        if source not in ("alipay", "wechat", "generic"):
            raise HTTPException(status_code=422, detail="source must be alipay, wechat, or generic")
        content = await file.read(MAX_IMPORT_BYTES + 1)
        if len(content) > MAX_IMPORT_BYTES:
            raise HTTPException(status_code=413, detail="Import file exceeds 10 MiB")
        mapping: dict[str, str] | None = None
        if column_mapping is not None:
            if len(column_mapping) > 4096:
                raise HTTPException(status_code=422, detail="column_mapping is too large")
            try:
                mapping = json.loads(column_mapping)
            except json.JSONDecodeError as exc:
                raise HTTPException(status_code=422, detail="column_mapping must be a JSON object") from exc
            if not isinstance(mapping, dict):
                raise HTTPException(status_code=422, detail="column_mapping must be a JSON object")
        try:
            rows = parse_bill(source, file.filename or "bill.csv", content, mapping)
        except BillImportError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
        if not rows:
            raise HTTPException(status_code=422, detail="No importable transactions found")

        preview_id = str(uuid.uuid4())
        with closing(connect(path)) as connection:
            connection.execute("BEGIN IMMEDIATE")
            prune_import_previews(connection)
            exclude_red_packets = settings(connection)["exclude_red_packets"]
            rules = _load_rules(connection)
            rows = [_prepare_import_row(row, exclude_red_packets, rules) for row in rows]
            existing = {
                row["dedupe_key"]
                for row in connection.execute("SELECT dedupe_key FROM transactions").fetchall()
            }
            seen: set[str] = set()
            new_count = 0
            duplicate_count = 0
            for row in rows:
                key = row["dedupe_key"]
                if key in existing or key in seen:
                    duplicate_count += 1
                else:
                    new_count += 1
                seen.add(key)
            created_at = datetime.now(timezone.utc)
            connection.execute(
                "INSERT INTO import_previews (id, source, created_at, rows_json) VALUES (?, ?, ?, ?)",
                (preview_id, source, created_at.isoformat(), json.dumps(rows, ensure_ascii=False)),
            )
            connection.commit()
            return {
                "preview_id": preview_id,
                "expires_at": (created_at + IMPORT_PREVIEW_TTL).isoformat(),
                "source": source,
                "total_rows": len(rows),
                "new_count": new_count,
                "duplicate_count": duplicate_count,
                "skipped_count": 0,
                "rows": [_preview_row(row) for row in rows[:10]],
                "warnings": (
                    ["缺少交易单号的完全相同记录可能被识别为重复，请核对预览。"]
                    if any(not row.get("external_id") for row in rows) else []
                ),
            }

    @app.get("/api/v1/imports/{preview_id}/rows", dependencies=[Depends(authorize)])
    def review_import(preview_id: uuid.UUID, offset: int = Query(default=0, ge=0), limit: int = Query(default=50, ge=1, le=100)) -> dict[str, Any]:
        with closing(connect(path)) as connection:
            connection.execute("BEGIN IMMEDIATE")
            prune_import_previews(connection)
            preview = connection.execute("SELECT * FROM import_previews WHERE id = ?", (str(preview_id),)).fetchone()
            if preview is None or preview["committed_at"] is not None:
                connection.commit()
                raise HTTPException(status_code=404, detail="Preview unavailable")
            rows = json.loads(preview["rows_json"])
            existing = {r[0] for r in connection.execute("SELECT dedupe_key FROM transactions")}
            seen: set[str] = set()
            result = []
            for index, row in enumerate(rows):
                duplicate = row["dedupe_key"] in existing or row["dedupe_key"] in seen
                seen.add(row["dedupe_key"])
                if offset <= index < offset + limit:
                    result.append({**_preview_row(row), "duplicate": duplicate})
            connection.commit()
            return {"rows": result, "total": len(rows), "offset": offset}

    @app.post("/api/v1/imports/{preview_id}/commit", dependencies=[Depends(authorize)])
    def commit_import(preview_id: uuid.UUID) -> dict[str, Any]:
        with closing(connect(path)) as connection:
            connection.execute("BEGIN IMMEDIATE")
            prune_import_previews(connection)
            preview = connection.execute("SELECT * FROM import_previews WHERE id = ?", (str(preview_id),)).fetchone()
            if preview is None:
                connection.commit()
                raise HTTPException(status_code=404, detail="Preview not found or expired; import the file again")
            if preview["commit_response_json"] is not None:
                result = json.loads(preview["commit_response_json"])
                connection.commit()
                return result

            rows = json.loads(preview["rows_json"])
            exclude_red_packets = settings(connection)["exclude_red_packets"]
            imported = 0
            duplicate = 0
            for row in rows:
                if connection.execute(
                    "SELECT 1 FROM transactions WHERE dedupe_key = ?", (row["dedupe_key"],)
                ).fetchone():
                    duplicate += 1
                    continue
                transaction_id = str(uuid.uuid5(uuid.NAMESPACE_URL, "ledger:" + row["dedupe_key"]))
                excluded = bool(row.get("excluded", False))
                reason = row.get("exclusion_reason")
                # A preview can outlive a change to the default policy. Keep
                # explicit rule decisions and failed payments, but commit other
                # red packets under the policy active in this transaction.
                if (
                    row["kind"] == "red_packet"
                    and row.get("_excluded_override") is None
                    and reason != "closed_or_failed"
                ):
                    excluded = exclude_red_packets
                    reason = "default_red_packet" if excluded else None
                revision = next_revision(connection)
                connection.execute(
                    """INSERT INTO transactions (
                        id, source, external_id, dedupe_key, occurred_at, amount_cents,
                        direction, kind, merchant, description, category, tags_json, note,
                        excluded, exclusion_reason, excluded_override, refund_of_id, raw_json, version, revision
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?)""",
                    (
                        transaction_id, row["source"], row.get("external_id"), row["dedupe_key"],
                        row["occurred_at"], row["amount_cents"], row["direction"], row["kind"],
                        row.get("merchant", ""), row.get("description", ""), row.get("category"),
                        json.dumps(row.get("tags", []), ensure_ascii=False), row.get("note", ""),
                        int(excluded), reason, row.get("_excluded_override"), row.get("refund_of_id"),
                        json.dumps(row.get("raw_data", {}), ensure_ascii=False), revision,
                    ),
                )
                imported += 1
            result = {
                "imported": imported,
                "duplicate": duplicate,
                "skipped": 0,
                "revision": current_revision(connection),
            }
            connection.execute(
                "UPDATE import_previews SET committed_at = ?, commit_response_json = ?, rows_json = '[]' WHERE id = ?",
                (datetime.now(timezone.utc).isoformat(), json.dumps(result), str(preview_id)),
            )
            connection.commit()
            return result

    @app.get("/api/v1/reports/month", dependencies=[Depends(authorize)])
    def monthly_report(year: int = Query(ge=1, le=9999), month: int = Query(ge=1, le=12)) -> dict[str, Any]:
        with closing(connect(path)) as connection:
            connection.execute("BEGIN")
            result = _build_report(connection, year, month)
            connection.commit()
            return result

    @app.get("/api/v1/reports/year", dependencies=[Depends(authorize)])
    def yearly_report(year: int = Query(ge=1, le=9999)) -> dict[str, Any]:
        with closing(connect(path)) as connection:
            # One read transaction keeps all twelve months on the same snapshot.
            connection.execute("BEGIN")
            months = [_build_report(connection, year, month) for month in range(1, 13)]
            categories: dict[str, int] = defaultdict(int)
            for monthly in months:
                for category in monthly["category_totals"]:
                    categories[category["category"]] += category["amount_cents"]
            totals = {
                key: sum(monthly[key] for monthly in months)
                for key in (
                    "total_actual_consumption_cents", "gross_consumption_cents",
                    "applied_refunds_cents", "over_refund_cents", "total_income_cents",
                    "unlinked_refunds_cents", "unlinked_refunds_count",
                )
            }
            result = {
                "year": year,
                "revision": current_revision(connection),
                **totals,
                "category_totals": [
                    {"category": name, "amount_cents": amount}
                    for name, amount in sorted(categories.items(), key=lambda item: (-item[1], item[0]))
                ],
                "months": months,
            }
            connection.commit()
            return result

    @app.get("/api/v1/export.csv", dependencies=[Depends(authorize)])
    def export_csv(
        year: int | None = Query(default=None, ge=1, le=9999),
        month: int | None = Query(default=None, ge=1, le=12),
        redact: bool = False,
    ) -> Response:
        if month is not None and year is None:
            raise HTTPException(status_code=422, detail="year is required when month is supplied")
        with closing(connect(path)) as connection:
            rows = connection.execute("SELECT * FROM transactions ORDER BY occurred_at, id").fetchall()

        fields = [
            "id", "source", "external_id", "occurred_at", "amount_cents", "direction", "kind",
            "merchant", "description", "category", "tags", "note", "excluded",
            "exclusion_reason", "refund_of_id", "version", "revision",
        ]
        output = io.StringIO(newline="")
        writer = csv.DictWriter(output, fieldnames=fields)
        writer.writeheader()
        # Each redacted export preserves joins and grouping only within that
        # export. Stable ledger IDs and user-entered category names stay local.
        redacted_ids = {row["id"]: str(uuid.uuid4()) for row in rows} if redact else {}
        redacted_categories: dict[str, str] = {}
        for row in rows:
            if year is not None and int(row["occurred_at"][:4]) != year:
                continue
            if month is not None and int(row["occurred_at"][5:7]) != month:
                continue
            data = transaction_dict(row)
            data["tags"] = "|".join(data["tags"])
            if redact:
                for field in ("external_id", "merchant", "description", "tags", "note"):
                    data[field] = ""
                data["id"] = redacted_ids[data["id"]]
                data["refund_of_id"] = redacted_ids.get(data["refund_of_id"])
                if data["category"]:
                    category = data["category"]
                    data["category"] = redacted_categories.setdefault(
                        category, f"分类{len(redacted_categories) + 1}",
                    )
                if (data["exclusion_reason"] or "").startswith("rule:"):
                    data["exclusion_reason"] = "rule"
            for field in ("source", "external_id", "merchant", "description", "category", "tags", "note", "exclusion_reason"):
                if isinstance(data.get(field), str):
                    data[field] = _safe_csv_text(data[field])
            writer.writerow(data)
        filename = "ledger.csv" if year is None else f"ledger-{year}" + (f"-{month:02d}" if month else "") + ".csv"
        return Response(
            content="\ufeff" + output.getvalue(),
            media_type="text/csv; charset=utf-8",
            headers={"Content-Disposition": f'attachment; filename="{filename}"'},
        )

    return app


app = create_app()
