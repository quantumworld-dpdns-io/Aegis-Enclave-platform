"""契約第 2 節路由：healthz、records、retire、metrics。不開 /docs。"""

from __future__ import annotations

import base64
import json
import uuid
from typing import Annotated, cast

from fastapi import APIRouter, Depends, Request, Response

from app.api.deps import request_id_header, role_header, subject_header
from app.api.schemas import (
    HealthResponse,
    RecordCreateRequest,
    RecordCreateResponse,
    RecordReadResponse,
    RetireRequest,
    RetireResponse,
)
from app.crypto.envelope import Envelope, open_envelope, seal_envelope
from app.kms.base import DataKey, EncryptionContext, KeyProvider
from app.masking.policy import MaskingRole, apply_mask
from app.observability.logging import bind_request, get_logger
from app.observability.metrics import KMS_DECRYPT, KMS_ENCRYPT, observe_kms, render_metrics

router = APIRouter()


def _provider(request: Request) -> KeyProvider:
    return cast("KeyProvider", request.app.state.provider)


@router.get("/internal/healthz", response_model=HealthResponse)
async def healthz() -> HealthResponse:
    return HealthResponse()


@router.get("/metrics")
async def metrics() -> Response:
    payload, content_type = render_metrics()
    return Response(content=payload, media_type=content_type)


@router.post("/internal/v1/records", response_model=RecordCreateResponse, status_code=201)
async def create_record(
    request: Request,
    body: RecordCreateRequest,
    request_id: Annotated[str, Depends(request_id_header)],
    subject: Annotated[str, Depends(subject_header)],
    role: Annotated[MaskingRole, Depends(role_header)],
) -> RecordCreateResponse:
    bind_request(request_id=request_id, subject=subject, resource="/internal/v1/records")
    provider = _provider(request)
    record_id = str(uuid.uuid4())
    ctx = EncryptionContext(record_id=record_id, tenant=body.tenant, purpose="vault")
    plaintext = body.model_dump_json().encode("utf-8")

    async def _gen() -> DataKey:
        return await provider.generate_data_key(ctx)

    data_key = await observe_kms(provider.driver_name, "encrypt", _gen)
    try:
        wire = seal_envelope(
            plaintext=plaintext,
            dek=data_key.plaintext,
            wrapped_dek=data_key.wrapped,
            driver=provider.driver_name,
            key_id=provider.key_id,
            ctx=ctx,
        )
    finally:
        data_key.zeroize()
    request.app.state.store.put(record_id, wire)
    KMS_ENCRYPT.labels(driver=provider.driver_name, key_id=provider.key_id).inc()
    get_logger().info("record.created", record_id=record_id, role=role)
    return RecordCreateResponse(record_id=record_id, tenant=body.tenant)


@router.get("/internal/v1/records/{record_id}", response_model=RecordReadResponse)
async def read_record(
    request: Request,
    record_id: str,
    request_id: Annotated[str, Depends(request_id_header)],
    subject: Annotated[str, Depends(subject_header)],
    role: Annotated[MaskingRole, Depends(role_header)],
) -> RecordReadResponse:
    bind_request(
        request_id=request_id,
        subject=subject,
        resource=f"/internal/v1/records/{record_id}",
    )
    provider = _provider(request)
    wire = request.app.state.store.get(record_id)
    envelope = Envelope.decode(wire)
    ctx = envelope.encryption_context()
    wrapped = base64.b64decode(envelope.wrapped_dek, validate=True)

    async def _dec() -> bytes:
        return await provider.decrypt_data_key(wrapped, ctx)

    dek = await observe_kms(provider.driver_name, "decrypt", _dec)
    try:
        raw = open_envelope(wire, dek)
    finally:
        del dek
    KMS_DECRYPT.labels(
        driver=provider.driver_name,
        key_id=envelope.key_id,
        subject=subject,
    ).inc()
    payload = json.loads(raw.decode("utf-8"))
    masked = await apply_mask(payload, role, request.app.state.tokenizer)
    get_logger().info("record.read", record_id=record_id, role=role)
    return RecordReadResponse(record_id=record_id, **masked)


@router.post("/internal/v1/chain/retire", response_model=RetireResponse)
async def retire(
    request: Request,
    body: RetireRequest,
    request_id: Annotated[str, Depends(request_id_header)],
    subject: Annotated[str, Depends(subject_header)],
) -> RetireResponse:
    bind_request(request_id=request_id, subject=subject, resource="/internal/v1/chain/retire")
    beneficiary = body.beneficiary or subject
    tx_hash = await request.app.state.chain.retire(body.project_id, body.amount, beneficiary)
    get_logger().info("chain.retired", project_id=body.project_id)
    return RetireResponse(tx_hash=tx_hash, project_id=body.project_id, amount=body.amount)
