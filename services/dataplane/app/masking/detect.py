"""PII 型別偵測。信用卡必須過 Luhn，避免把任意 16 位數字當卡號。"""

from __future__ import annotations

import re
from typing import Literal

FieldType = Literal[
    "national_id",
    "card_number",
    "email",
    "phone",
    "iban",
    "holder_name",
]

# 台灣身分證：1 英文字 + 9 數字。檢查碼另做，格式先擋明顯假陽性。
_NATIONAL_ID = re.compile(r"^[A-Z][12]\d{8}$")
_EMAIL = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
_PHONE = re.compile(r"^(?:\+886-?|0)9\d{8}$")
_IBAN = re.compile(r"^[A-Z]{2}\d{2}[A-Z0-9]{10,30}$")
_CARD_DIGITS = re.compile(r"^\d{13,19}$")
_KNOWN_KEYS: dict[str, FieldType] = {
    "national_id": "national_id",
    "card_number": "card_number",
    "email": "email",
    "phone": "phone",
    "iban": "iban",
    "holder_name": "holder_name",
}


_CARD_LEN_MIN = 13
_CARD_LEN_MAX = 19
_LUHN_FOLD = 9


def luhn_ok(number: str) -> bool:
    """標準 Luhn：從右數偶數位乘 2，大於 9 再減 9。"""
    digits = [int(ch) for ch in number if ch.isdigit()]
    if not _CARD_LEN_MIN <= len(digits) <= _CARD_LEN_MAX:
        return False
    total = 0
    for index, raw in enumerate(reversed(digits)):
        value = raw
        if index % 2 == 1:
            value *= 2
            if value > _LUHN_FOLD:
                value -= _LUHN_FOLD
        total += value
    return total % 10 == 0


def detect_field(name: str, value: str) -> FieldType | None:
    """先看欄位名（明確標示的 PII），再退回值型態偵測。"""
    known = _KNOWN_KEYS.get(name)
    if known is not None:
        return known
    return classify_value(value)


def classify_value(value: str) -> FieldType | None:
    compact = value.strip()
    digits = re.sub(r"[\s-]", "", compact)
    phone = compact.replace(" ", "").replace("-", "")
    found: FieldType | None = None
    if _NATIONAL_ID.fullmatch(compact):
        found = "national_id"
    elif _CARD_DIGITS.fullmatch(digits) and luhn_ok(digits):
        found = "card_number"
    elif _EMAIL.fullmatch(compact):
        found = "email"
    elif _PHONE.fullmatch(phone):
        found = "phone"
    elif _IBAN.fullmatch(compact.upper()):
        found = "iban"
    return found


def looks_like_pii(value: str) -> bool:
    return classify_value(value) is not None
