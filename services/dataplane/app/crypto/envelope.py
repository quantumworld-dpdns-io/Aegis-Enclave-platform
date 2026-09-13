"""密文信封：格式嚴格符合 docs/CONTRACT.md 第 6 節。

落地值是「信封 JSON」再做一次 base64。aad 同時綁 AES-GCM 與 KMS context。
"""

from __future__ import annotations

import base64
import json
import secrets
from typing import Any

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from pydantic import BaseModel, Field, field_validator

from app.crypto.canonical import dumps_canonical
from app.errors import EnvelopeError
from app.kms.base import AES_256_KEY_BYTES, EncryptionContext

ENVELOPE_VERSION = 1
GCM_NONCE_BYTES = 12
ENVELOPE_JSON_KEYS = (
    "v",
    "driver",
    "key_id",
    "wrapped_dek",
    "nonce",
    "ciphertext",
    "aad",
)


class Envelope(BaseModel):
    """第 6 節信封的結構化表示；序列化時維持契約欄位名稱。"""

    v: int = Field(default=ENVELOPE_VERSION)
    driver: str
    key_id: str
    wrapped_dek: str
    nonce: str
    ciphertext: str
    aad: dict[str, str]

    @field_validator("v")
    @classmethod
    def _version_must_be_one(cls, value: int) -> int:
        if value != ENVELOPE_VERSION:
            msg = "不支援的信封版本"
            raise ValueError(msg)
        return value

    def to_wire_dict(self) -> dict[str, Any]:
        """依契約欄位順序輸出，避免多餘鍵混進落地 JSON。"""
        return {
            "v": self.v,
            "driver": self.driver,
            "key_id": self.key_id,
            "wrapped_dek": self.wrapped_dek,
            "nonce": self.nonce,
            "ciphertext": self.ciphertext,
            "aad": self.aad,
        }

    def encode(self) -> str:
        raw = json.dumps(self.to_wire_dict(), ensure_ascii=False, separators=(",", ":"))
        return base64.b64encode(raw.encode("utf-8")).decode("ascii")

    @classmethod
    def decode(cls, wire: str) -> Envelope:
        try:
            raw = base64.b64decode(wire, validate=True)
            payload = json.loads(raw.decode("utf-8"))
        except (ValueError, json.JSONDecodeError) as exc:
            msg = "信封解碼失敗"
            raise EnvelopeError("envelope_decode_failed", msg) from exc
        if not isinstance(payload, dict):
            msg = "信封必須是 JSON 物件"
            raise EnvelopeError("envelope_invalid", msg)
        extra = set(payload) - set(ENVELOPE_JSON_KEYS)
        missing = set(ENVELOPE_JSON_KEYS) - set(payload)
        if extra or missing:
            msg = "信封欄位與契約第 6 節不符"
            raise EnvelopeError("envelope_schema", msg)
        try:
            return cls.model_validate(payload)
        except ValueError as exc:
            msg = "信封內容不合法"
            raise EnvelopeError("envelope_invalid", msg) from exc

    def encryption_context(self) -> EncryptionContext:
        try:
            return EncryptionContext.model_validate(self.aad)
        except ValueError as exc:
            msg = "信封 aad 無法還原為 encryption context"
            raise EnvelopeError("envelope_aad", msg) from exc


def _b64encode(raw: bytes) -> str:
    return base64.b64encode(raw).decode("ascii")


def _b64decode(label: str, value: str) -> bytes:
    try:
        return base64.b64decode(value, validate=True)
    except ValueError as exc:
        msg = f"{label} 不是合法 base64"
        raise EnvelopeError("envelope_b64", msg) from exc


def seal_envelope(  # noqa: PLR0913
    *,
    plaintext: bytes,
    dek: bytes,
    wrapped_dek: bytes,
    driver: str,
    key_id: str,
    ctx: EncryptionContext,
) -> str:
    """用 AES-256-GCM 封裝明文，aad 與 ctx 完全一致。"""
    if len(dek) != AES_256_KEY_BYTES:
        msg = "DEK 長度不正確"
        raise EnvelopeError("dek_length", msg)
    nonce = secrets.token_bytes(GCM_NONCE_BYTES)
    aad = ctx.as_kms_dict()
    aad_bytes = dumps_canonical(aad)
    ciphertext = AESGCM(dek).encrypt(nonce, plaintext, aad_bytes)
    envelope = Envelope(
        v=ENVELOPE_VERSION,
        driver=driver,
        key_id=key_id,
        wrapped_dek=_b64encode(wrapped_dek),
        nonce=_b64encode(nonce),
        ciphertext=_b64encode(ciphertext),
        aad=aad,
    )
    return envelope.encode()


def open_envelope(wire: str, dek: bytes) -> bytes:
    """用呼叫端解開的 DEK 解密。aad 被竄改時 GCM 會拒絕。"""
    envelope = Envelope.decode(wire)
    nonce = _b64decode("nonce", envelope.nonce)
    ciphertext = _b64decode("ciphertext", envelope.ciphertext)
    if len(nonce) != GCM_NONCE_BYTES:
        msg = "nonce 長度必須是 12 bytes"
        raise EnvelopeError("nonce_length", msg)
    aad_bytes = dumps_canonical(envelope.aad)
    try:
        return AESGCM(dek).decrypt(nonce, ciphertext, aad_bytes)
    except InvalidTag as exc:
        msg = "紀錄完整性檢查失敗"
        raise EnvelopeError("integrity_failed", msg) from exc
