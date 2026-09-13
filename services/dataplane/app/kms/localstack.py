"""LocalStack KMS driver。API 與 AWS 相同，只是打到 AEGIS_KMS_ENDPOINT。"""

from __future__ import annotations

from typing import TYPE_CHECKING

from app.kms.aws import AwsKeyProvider

if TYPE_CHECKING:
    from mypy_boto3_kms import KMSClient

    from app.config import Settings


class LocalstackKeyProvider(AwsKeyProvider):
    """預設 driver：完全離線、與 aws driver 共用同一組合約測試。"""

    driver_name = "localstack"

    @classmethod
    def from_settings(cls, settings: Settings) -> LocalstackKeyProvider:
        import boto3

        client: KMSClient = boto3.client(
            "kms",
            region_name=settings.AWS_REGION,
            endpoint_url=settings.AEGIS_KMS_ENDPOINT,
        )
        return cls(client, settings.AEGIS_KMS_KEY_ID)
