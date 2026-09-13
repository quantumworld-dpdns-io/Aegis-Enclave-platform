"""儲存層與信封 schema 邊界。"""

from __future__ import annotations

import base64
import json

import pytest
from app.crypto.envelope import Envelope, seal_envelope
from app.crypto.store import RecordStore
from app.errors import EnvelopeError, RecordNotFoundError
from app.kms.base import EncryptionContext
from app.observability.logging import bind_request


def test_store_put_get_and_missing() -> None:
    store = RecordStore()
    store.put("r1", "wire")
    assert "r1" in store
    assert store.get("r1") == "wire"
    with pytest.raises(RecordNotFoundError):
        store.get("missing")


def test_envelope_schema_rejects_extra_and_bad_version() -> None:
    ctx = EncryptionContext(record_id="r", tenant="t", purpose="vault")
    dek = b"k" * 32
    wire = seal_envelope(
        plaintext=b"x",
        dek=dek,
        wrapped_dek=b"w",
        driver="localstack",
        key_id="alias/aegis-master",
        ctx=ctx,
    )
    payload = json.loads(base64.b64decode(wire))
    payload["extra"] = "nope"
    bad = base64.b64encode(json.dumps(payload).encode()).decode()
    with pytest.raises(EnvelopeError):
        Envelope.decode(bad)

    payload = json.loads(base64.b64decode(wire))
    payload["v"] = 99
    bad_ver = base64.b64encode(json.dumps(payload).encode()).decode()
    with pytest.raises(EnvelopeError):
        Envelope.decode(bad_ver)

    with pytest.raises(EnvelopeError):
        Envelope.decode(base64.b64encode(b"[]").decode())


def test_bind_request_sets_context() -> None:
    bind_request(request_id="r", subject="sub_aa", resource="/x")
