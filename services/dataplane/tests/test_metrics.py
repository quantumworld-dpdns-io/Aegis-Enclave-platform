"""KMS 觀察器與指標名稱穩定性。"""

from __future__ import annotations

import pytest
from app.errors import KmsError
from app.observability.metrics import KMS_ERRORS, observe_kms, render_metrics


@pytest.mark.asyncio
async def test_observe_kms_counts_errors() -> None:
    before = KMS_ERRORS.labels(driver="localstack", operation="encrypt")._value.get()

    async def _boom() -> None:
        msg = "無法產生資料金鑰"
        raise KmsError("generate_data_key", msg)

    with pytest.raises(KmsError):
        await observe_kms("localstack", "encrypt", _boom)
    after = KMS_ERRORS.labels(driver="localstack", operation="encrypt")._value.get()
    assert after == before + 1


@pytest.mark.asyncio
async def test_observe_kms_wraps_unexpected() -> None:
    async def _boom() -> None:
        msg = "network"
        raise RuntimeError(msg)

    with pytest.raises(KmsError):
        await observe_kms("aws", "decrypt", _boom)


def test_render_metrics_contains_contract_names() -> None:
    payload, content_type = render_metrics()
    text = payload.decode()
    assert "text/plain" in content_type
    assert "aegis_kms_encrypt_total" in text
    assert "aegis_masking_bypass_total" in text
