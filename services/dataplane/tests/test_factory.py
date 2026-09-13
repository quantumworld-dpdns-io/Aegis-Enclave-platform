"""工廠函式依 AEGIS_KMS_DRIVER 選出對應實作。"""

from __future__ import annotations

from app.config import Settings
from app.kms.aws import AwsKeyProvider
from app.kms.factory import build_key_provider
from app.kms.localstack import LocalstackKeyProvider
from app.kms.vault import FakeVaultBackend, VaultKeyProvider


def test_factory_localstack(aws_credentials: None) -> None:
    settings = Settings(AEGIS_KMS_DRIVER="localstack")
    provider = build_key_provider(settings)
    assert isinstance(provider, LocalstackKeyProvider)
    assert provider.driver_name == "localstack"


def test_factory_aws(aws_credentials: None) -> None:
    settings = Settings(AEGIS_KMS_DRIVER="aws")
    provider = build_key_provider(settings)
    assert isinstance(provider, AwsKeyProvider)
    assert provider.driver_name == "aws"


def test_factory_vault_with_fake() -> None:
    settings = Settings(AEGIS_KMS_DRIVER="vault")
    provider = build_key_provider(settings, vault_backend=FakeVaultBackend())
    assert isinstance(provider, VaultKeyProvider)
    assert provider.driver_name == "vault"
