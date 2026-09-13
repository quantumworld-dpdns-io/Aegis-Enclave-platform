"""API 4xx/5xx、角色遮罩、信封落地、指標名稱與未開放路徑。"""

from __future__ import annotations

import base64
import json

import httpx
import pytest
from app.crypto.envelope import Envelope
from app.main import AppState

HEADERS = {
    "X-Aegis-Request-ID": "req-test-1",
    "X-Aegis-Subject": "sub_aaaaaaaaaaaaaaaa",
    "X-Aegis-Role": "vault_reader",
}

PAYLOAD = {
    "tenant": "acme",
    "holder_name": "王小明",
    "national_id": "A123456789",
    "iban": "TW12ACME00001234567890",
    "amount": "128000.00",
}


@pytest.mark.asyncio
async def test_healthz(client: httpx.AsyncClient) -> None:
    resp = await client.get("/internal/healthz")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


@pytest.mark.asyncio
async def test_docs_and_unknown_routes_are_closed(client: httpx.AsyncClient) -> None:
    assert (await client.get("/docs")).status_code == 404
    assert (await client.get("/openapi.json")).status_code == 404
    assert (await client.get("/internal/v1/keys")).status_code == 404


@pytest.mark.asyncio
async def test_create_and_read_with_roles(client: httpx.AsyncClient) -> None:
    created = await client.post("/internal/v1/records", json=PAYLOAD, headers=HEADERS)
    assert created.status_code == 201
    record_id = created.json()["record_id"]

    reader = await client.get(f"/internal/v1/records/{record_id}", headers=HEADERS)
    assert reader.status_code == 200
    body = reader.json()
    assert body["national_id"] != "A123456789"
    assert "A123456789" not in reader.text
    assert body["amount"] == "128000.00"

    admin_headers = {**HEADERS, "X-Aegis-Role": "vault_admin"}
    admin = await client.get(f"/internal/v1/records/{record_id}", headers=admin_headers)
    assert admin.json()["national_id"] == "A123456789"

    auditor_headers = {**HEADERS, "X-Aegis-Role": "auditor"}
    auditor = await client.get(f"/internal/v1/records/{record_id}", headers=auditor_headers)
    assert str(auditor.json()["national_id"]).startswith("tok_")


@pytest.mark.asyncio
async def test_stored_value_is_contract_envelope(
    client: httpx.AsyncClient,
    app_state: AppState,
) -> None:
    created = await client.post("/internal/v1/records", json=PAYLOAD, headers=HEADERS)
    record_id = created.json()["record_id"]
    wire = app_state.store.get(record_id)
    envelope = Envelope.decode(wire)
    assert envelope.v == 1
    assert envelope.driver == "localstack"
    assert envelope.aad["purpose"] == "vault"
    assert envelope.aad["tenant"] == "acme"
    raw = json.loads(base64.b64decode(wire))
    assert "A123456789" not in json.dumps(raw)


@pytest.mark.asyncio
async def test_missing_record_is_404(client: httpx.AsyncClient) -> None:
    resp = await client.get("/internal/v1/records/does-not-exist", headers=HEADERS)
    assert resp.status_code == 404
    assert "A123456789" not in resp.text


@pytest.mark.asyncio
async def test_validation_error_is_422(client: httpx.AsyncClient) -> None:
    resp = await client.post("/internal/v1/records", json={"tenant": ""}, headers=HEADERS)
    assert resp.status_code == 422


@pytest.mark.asyncio
async def test_retire_degrades_without_deployment(client: httpx.AsyncClient) -> None:
    resp = await client.post(
        "/internal/v1/chain/retire",
        json={"projectId": 1, "amount": 10},
        headers=HEADERS,
    )
    assert resp.status_code == 503
    assert resp.json()["code"] == "chain_unconfigured"


@pytest.mark.asyncio
async def test_metrics_names(client: httpx.AsyncClient) -> None:
    await client.post("/internal/v1/records", json=PAYLOAD, headers=HEADERS)
    resp = await client.get("/metrics")
    assert resp.status_code == 200
    text = resp.text
    for name in (
        "aegis_kms_encrypt_total",
        "aegis_kms_decrypt_total",
        "aegis_kms_operation_duration_seconds",
        "aegis_kms_errors_total",
        "aegis_masking_applied_total",
        "aegis_masking_bypass_total",
        "aegis_chain_calls_total",
    ):
        assert name in text
    assert "A123456789" not in text
