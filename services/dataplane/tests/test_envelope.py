"""信封往返、欄位契約、竄改 aad / ciphertext / wrapped DEK 必須失敗。"""

from __future__ import annotations

import base64
import json

import pytest
from app.crypto.envelope import Envelope, open_envelope, seal_envelope
from app.errors import EnvelopeError, KmsError
from app.kms.base import DataKey, EncryptionContext, KeyProvider


def _tamper_wire(wire: str, mutator: object) -> str:
    raw = json.loads(base64.b64decode(wire))
    mutator(raw)  # type: ignore[operator]
    return base64.b64encode(json.dumps(raw, separators=(",", ":")).encode()).decode()


@pytest.mark.asyncio
async def test_envelope_roundtrip(provider: KeyProvider) -> None:
    ctx = EncryptionContext(record_id="r1", tenant="acme", purpose="vault")
    data_key = await provider.generate_data_key(ctx)
    plaintext = b'{"holder_name":"hidden"}'
    wire = seal_envelope(
        plaintext=plaintext,
        dek=data_key.plaintext,
        wrapped_dek=data_key.wrapped,
        driver=provider.driver_name,
        key_id=provider.key_id,
        ctx=ctx,
    )
    envelope = Envelope.decode(wire)
    assert envelope.v == 1
    assert envelope.driver == provider.driver_name
    assert envelope.key_id == provider.key_id
    assert set(envelope.to_wire_dict()) == {
        "v",
        "driver",
        "key_id",
        "wrapped_dek",
        "nonce",
        "ciphertext",
        "aad",
    }
    assert envelope.aad == ctx.as_kms_dict()
    dek = await provider.decrypt_data_key(data_key.wrapped, ctx)
    assert open_envelope(wire, dek) == plaintext
    data_key.zeroize()


@pytest.mark.asyncio
async def test_tampered_ciphertext_rejected(provider: KeyProvider) -> None:
    ctx = EncryptionContext(record_id="r1", tenant="acme", purpose="vault")
    data_key = await provider.generate_data_key(ctx)
    wire = seal_envelope(
        plaintext=b"secret",
        dek=data_key.plaintext,
        wrapped_dek=data_key.wrapped,
        driver=provider.driver_name,
        key_id=provider.key_id,
        ctx=ctx,
    )

    def flip(payload: dict[str, object]) -> None:
        raw = bytearray(base64.b64decode(str(payload["ciphertext"])))
        raw[0] ^= 0x01
        payload["ciphertext"] = base64.b64encode(raw).decode()

    bad = _tamper_wire(wire, flip)
    with pytest.raises(EnvelopeError):
        open_envelope(bad, data_key.plaintext)
    data_key.zeroize()


@pytest.mark.asyncio
async def test_tampered_aad_rejected(provider: KeyProvider) -> None:
    ctx = EncryptionContext(record_id="r1", tenant="acme", purpose="vault")
    data_key = await provider.generate_data_key(ctx)
    wire = seal_envelope(
        plaintext=b"secret",
        dek=data_key.plaintext,
        wrapped_dek=data_key.wrapped,
        driver=provider.driver_name,
        key_id=provider.key_id,
        ctx=ctx,
    )

    def change_aad(payload: dict[str, object]) -> None:
        aad = dict(payload["aad"])  # type: ignore[arg-type]
        aad["tenant"] = "other"
        payload["aad"] = aad

    bad = _tamper_wire(wire, change_aad)
    with pytest.raises(EnvelopeError):
        open_envelope(bad, data_key.plaintext)
    data_key.zeroize()


@pytest.mark.asyncio
async def test_swapped_wrapped_dek_rejected(provider: KeyProvider) -> None:
    ctx_a = EncryptionContext(record_id="a", tenant="acme", purpose="vault")
    ctx_b = EncryptionContext(record_id="b", tenant="acme", purpose="vault")
    key_a = await provider.generate_data_key(ctx_a)
    key_b = await provider.generate_data_key(ctx_b)
    wire = seal_envelope(
        plaintext=b"secret-a",
        dek=key_a.plaintext,
        wrapped_dek=key_a.wrapped,
        driver=provider.driver_name,
        key_id=provider.key_id,
        ctx=ctx_a,
    )

    def swap(payload: dict[str, object]) -> None:
        payload["wrapped_dek"] = base64.b64encode(key_b.wrapped).decode()

    bad = _tamper_wire(wire, swap)
    envelope = Envelope.decode(bad)
    wrapped = base64.b64decode(envelope.wrapped_dek)
    with pytest.raises(KmsError):
        await provider.decrypt_data_key(wrapped, ctx_a)
    key_a.zeroize()
    key_b.zeroize()


def test_invalid_wire_rejected() -> None:
    with pytest.raises(EnvelopeError):
        Envelope.decode("%%%not-base64%%%")


def test_datakey_length() -> None:
    with pytest.raises(ValueError, match="32"):
        DataKey(plaintext=b"short", wrapped=b"x")
