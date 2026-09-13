"""依 AEGIS_KMS_DRIVER 選出 KeyProvider。呼叫端不該知道三個 driver 的建構細節。"""

from __future__ import annotations

from app.config import Settings
from app.kms.aws import AwsKeyProvider
from app.kms.base import KeyProvider
from app.kms.localstack import LocalstackKeyProvider
from app.kms.vault import VaultBackend, VaultKeyProvider


def build_key_provider(
    settings: Settings,
    *,
    vault_backend: VaultBackend | None = None,
) -> KeyProvider:
    """vault_backend 僅供測試注入 fake，正式環境走 HTTP。"""
    driver = settings.AEGIS_KMS_DRIVER
    if driver == "localstack":
        return LocalstackKeyProvider.from_settings(settings)
    if driver == "aws":
        return AwsKeyProvider.from_settings(settings)
    return VaultKeyProvider.from_settings(
        settings.AEGIS_VAULT_ADDR,
        settings.AEGIS_VAULT_TOKEN,
        settings.AEGIS_VAULT_TRANSIT_KEY,
        backend=vault_backend,
    )
