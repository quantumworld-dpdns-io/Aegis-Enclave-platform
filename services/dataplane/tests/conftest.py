"""共用 fixture：moto 模擬 AWS/LocalStack KMS，Vault 走 in-memory fake。"""

from __future__ import annotations

from collections.abc import AsyncIterator, Iterator

import boto3
import httpx
import pytest
from app.chain.client import ChainClient
from app.config import Settings
from app.crypto.store import RecordStore
from app.kms.aws import AwsKeyProvider
from app.kms.base import KeyProvider
from app.kms.localstack import LocalstackKeyProvider
from app.kms.vault import FakeVaultBackend, VaultKeyProvider
from app.main import AppState, create_app
from app.masking.tokenize import Tokenizer
from moto import mock_aws
from mypy_boto3_kms import KMSClient

REGION = "ap-northeast-1"
MASTER_ALIAS = "alias/aegis-master"
PSEUDONYM_ALIAS = "alias/aegis-pseudonym"


@pytest.fixture
def aws_credentials(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    monkeypatch.setenv("AWS_SECURITY_TOKEN", "testing")
    monkeypatch.setenv("AWS_SESSION_TOKEN", "testing")
    monkeypatch.setenv("AWS_DEFAULT_REGION", REGION)
    monkeypatch.setenv("AWS_REGION", REGION)


@pytest.fixture
def kms_client(aws_credentials: None) -> Iterator[KMSClient]:
    with mock_aws():
        client: KMSClient = boto3.client("kms", region_name=REGION)
        master = client.create_key(KeyUsage="ENCRYPT_DECRYPT", KeySpec="SYMMETRIC_DEFAULT")
        client.create_alias(AliasName=MASTER_ALIAS, TargetKeyId=master["KeyMetadata"]["KeyId"])
        try:
            hmac_key = client.create_key(KeyUsage="GENERATE_VERIFY_MAC", KeySpec="HMAC_256")
            client.create_alias(
                AliasName=PSEUDONYM_ALIAS,
                TargetKeyId=hmac_key["KeyMetadata"]["KeyId"],
            )
        except client.exceptions.ClientError:
            # 部分 moto 版本尚未支援 HMAC 金鑰，退回對稱金鑰讓 driver 走快取路徑。
            extra = client.create_key(KeyUsage="ENCRYPT_DECRYPT", KeySpec="SYMMETRIC_DEFAULT")
            client.create_alias(
                AliasName=PSEUDONYM_ALIAS,
                TargetKeyId=extra["KeyMetadata"]["KeyId"],
            )
        yield client


@pytest.fixture
def localstack_provider(kms_client: KMSClient) -> LocalstackKeyProvider:
    return LocalstackKeyProvider(kms_client, MASTER_ALIAS)


@pytest.fixture
def aws_provider(kms_client: KMSClient) -> AwsKeyProvider:
    return AwsKeyProvider(kms_client, MASTER_ALIAS)


@pytest.fixture
def vault_provider() -> VaultKeyProvider:
    return VaultKeyProvider(FakeVaultBackend(), "aegis-master")


@pytest.fixture(params=["localstack", "aws", "vault"])
def provider(
    request: pytest.FixtureRequest,
    localstack_provider: LocalstackKeyProvider,
    aws_provider: AwsKeyProvider,
    vault_provider: VaultKeyProvider,
) -> KeyProvider:
    mapping: dict[str, KeyProvider] = {
        "localstack": localstack_provider,
        "aws": aws_provider,
        "vault": vault_provider,
    }
    return mapping[request.param]


@pytest.fixture
def settings() -> Settings:
    return Settings(
        AEGIS_KMS_DRIVER="localstack",
        AEGIS_CARBON_CONTRACT_ADDR="",
        AEGIS_LOG_LEVEL="info",
    )


@pytest.fixture
def app_state(localstack_provider: LocalstackKeyProvider, settings: Settings) -> AppState:
    return AppState(
        settings,
        provider=localstack_provider,
        store=RecordStore(),
        tokenizer=Tokenizer(localstack_provider, PSEUDONYM_ALIAS),
        chain=ChainClient(settings, address=None),
    )


@pytest.fixture
async def client(app_state: AppState, settings: Settings) -> AsyncIterator[httpx.AsyncClient]:
    app = create_app(settings, state=app_state)
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as session:
        yield session
