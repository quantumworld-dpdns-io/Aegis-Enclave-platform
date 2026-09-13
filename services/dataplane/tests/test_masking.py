"""PII 偵測（含 Luhn）與角色動態遮罩。"""

from __future__ import annotations

import pytest
from app.kms.base import KeyProvider
from app.masking.detect import classify_value, detect_field, looks_like_pii, luhn_ok
from app.masking.policy import apply_mask
from app.masking.tokenize import Tokenizer

# Visa 測試卡號，通過 Luhn，非正式卡。
VISA = "4111111111111111"
BAD_CARD = "4111111111111112"
NID = "A123456789"


def test_luhn_true_and_false() -> None:
    assert luhn_ok(VISA)
    assert not luhn_ok(BAD_CARD)


def test_detect_known_types() -> None:
    assert detect_field("national_id", NID) == "national_id"
    assert detect_field("card_number", VISA) == "card_number"
    assert detect_field("email", "a@example.com") == "email"
    assert detect_field("phone", "0912345678") == "phone"
    assert detect_field("iban", "TW12ACME00001234567890") == "iban"
    assert detect_field("holder_name", "王小明") == "holder_name"


def test_value_classifier_and_false_positive() -> None:
    assert classify_value(VISA) == "card_number"
    assert classify_value(BAD_CARD) is None
    assert classify_value("not-pii") is None
    assert looks_like_pii(NID)
    assert not looks_like_pii("hello")


@pytest.mark.asyncio
async def test_role_masking_levels(provider: KeyProvider) -> None:
    tokenizer = Tokenizer(provider, provider.key_id)
    record = {
        "tenant": "acme",
        "holder_name": "王小明",
        "national_id": NID,
        "card_number": VISA,
        "email": "wang@example.com",
        "phone": "0912345678",
        "iban": "TW12ACME00001234567890",
        "amount": "128000.00",
    }
    admin = await apply_mask(record, "vault_admin", tokenizer)
    assert admin["national_id"] == NID
    assert admin["amount"] == "128000.00"

    reader = await apply_mask(record, "vault_reader", tokenizer)
    assert reader["national_id"] != NID
    assert reader["national_id"].startswith("A")
    assert reader["card_number"].endswith("1111")
    assert reader["email"].startswith("w")
    assert "@example.com" in str(reader["email"])
    assert reader["amount"] == "128000.00"
    assert NID not in str(reader)

    auditor = await apply_mask(record, "auditor", tokenizer)
    again = await apply_mask(record, "unknown", tokenizer)
    assert auditor["national_id"] == again["national_id"]
    assert str(auditor["national_id"]).startswith("tok_")
    assert NID not in str(auditor)
