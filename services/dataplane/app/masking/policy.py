"""依 X-Aegis-Role 決定遮罩強度。Cilium 只放行 gateway，這不是對外信任邊界。"""

from __future__ import annotations

import json
from typing import Any, Literal

from app.masking.detect import FieldType, detect_field
from app.masking.tokenize import Tokenizer
from app.observability.metrics import MASKING_APPLIED, MASKING_BYPASS

MaskingRole = Literal["vault_admin", "vault_reader", "auditor", "unknown"]
_PII_KEYS = (
    "national_id",
    "card_number",
    "email",
    "phone",
    "iban",
    "holder_name",
)


def parse_role(raw: str | None) -> MaskingRole:
    if raw == "vault_admin":
        return "vault_admin"
    if raw == "vault_reader":
        return "vault_reader"
    if raw == "auditor":
        return "auditor"
    return "unknown"


def _partial(field: FieldType, value: str) -> str:
    """部分遮罩：留下可辨識的尾碼，中間打星號。"""
    if field == "email":
        local, _, domain = value.partition("@")
        head = local[:1] if local else "*"
        return f"{head}***@{domain}"
    if field == "holder_name":
        if len(value) <= 1:
            return "*"
        return value[0] + "*" * (len(value) - 1)
    if field == "national_id":
        return f"{value[0]}******{value[-3:]}"
    digits = "".join(ch for ch in value if ch.isalnum())
    visible_tail = 4
    tail = digits[-visible_tail:] if len(digits) >= visible_tail else digits
    return f"{'*' * 12}{tail}"


async def apply_mask(
    record: dict[str, Any],
    role: MaskingRole,
    tokenizer: Tokenizer,
) -> dict[str, Any]:
    """vault_admin 明文；vault_reader 部分遮罩；其餘完全 tokenization。"""
    masked: dict[str, Any] = {}
    for key, value in record.items():
        if not isinstance(value, str) or key not in _PII_KEYS:
            masked[key] = value
            continue
        field = detect_field(key, value)
        if field is None:
            masked[key] = value
            continue
        if role == "vault_admin":
            # 授權下的明文不是失效；bypass 指標只留給「本該遮卻漏了」。
            masked[key] = value
            continue
        if role == "vault_reader":
            masked[key] = _partial(field, value)
        else:
            masked[key] = await tokenizer.token(value)
        MASKING_APPLIED.labels(field_type=field).inc()

    if role != "vault_admin":
        _detect_leak(record, masked)
    return masked


def _detect_leak(original: dict[str, Any], masked: dict[str, Any]) -> None:
    """回應裡若還看得到原始 PII 全文，視為遮罩管線失效。"""
    blob = json.dumps(masked, ensure_ascii=False)
    for key in _PII_KEYS:
        raw = original.get(key)
        if isinstance(raw, str) and raw and raw in blob:
            field: FieldType = key  # type: ignore[assignment]
            MASKING_BYPASS.labels(field_type=field, reason="plaintext_escaped").inc()
