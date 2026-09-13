"""三個 KeyProvider 跑同一組行為契約，確保切換 driver 不改呼叫端語意。"""

from __future__ import annotations

import pytest
from app.errors import KmsError
from app.kms.base import EncryptionContext, KeyProvider
from app.kms.vault import FakeVaultBackend, VaultKeyProvider

CTX = EncryptionContext(record_id="rec-1", tenant="acme", purpose="vault")
OTHER = EncryptionContext(record_id="rec-2", tenant="acme", purpose="vault")


@pytest.mark.asyncio
async def test_generate_and_decrypt_roundtrip(provider: KeyProvider) -> None:
    data_key = await provider.generate_data_key(CTX)
    with data_key:
        recovered = await provider.decrypt_data_key(data_key.wrapped, CTX)
        assert recovered == data_key.plaintext
    assert data_key.plaintext == b"\x00" * 32


@pytest.mark.asyncio
async def test_wrong_context_rejected(provider: KeyProvider) -> None:
    data_key = await provider.generate_data_key(CTX)
    with pytest.raises(KmsError):
        await provider.decrypt_data_key(data_key.wrapped, OTHER)
    data_key.zeroize()


@pytest.mark.asyncio
async def test_hmac_is_deterministic(provider: KeyProvider) -> None:
    first = await provider.hmac_sha256(provider.key_id, b"A123456789")
    second = await provider.hmac_sha256(provider.key_id, b"A123456789")
    other = await provider.hmac_sha256(provider.key_id, b"B987654321")
    assert first == second
    assert first != other


@pytest.mark.asyncio
async def test_rotate_returns_new_identifier(provider: KeyProvider) -> None:
    rotated = await provider.rotate(provider.key_id)
    assert isinstance(rotated, str)
    assert rotated


@pytest.mark.asyncio
async def test_vault_old_ciphertext_survives_rotate() -> None:
    backend = FakeVaultBackend()
    provider = VaultKeyProvider(backend, "aegis-master")
    data_key = await provider.generate_data_key(CTX)
    await provider.rotate("aegis-master")
    recovered = await provider.decrypt_data_key(data_key.wrapped, CTX)
    assert recovered == data_key.plaintext
    data_key.zeroize()
