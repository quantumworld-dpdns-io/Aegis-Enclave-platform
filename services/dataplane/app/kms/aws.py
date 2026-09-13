"""AWS KMS driver。與 localstack 共用 boto3 呼叫，差別只在 endpoint。"""

from __future__ import annotations

import hashlib
import hmac
import logging
from typing import TYPE_CHECKING

from botocore.exceptions import BotoCoreError, ClientError

from app.errors import KmsError
from app.kms.base import DataKey, EncryptionContext

if TYPE_CHECKING:
    from mypy_boto3_kms import KMSClient

    from app.config import Settings

_LOG = logging.getLogger(__name__)

# GenerateDataKey 每次都換 DEK，不能當決定論 HMAC 鹽。
# HMAC 金鑰類型走 GenerateMac；對稱金鑰則在行程內快取一次 DEK。
_HMAC_CACHE: dict[str, bytes] = {}


class AwsKeyProvider:
    """正式 AWS KMS：GenerateDataKey + Decrypt，encryption context 做用途綁定。"""

    driver_name = "aws"

    def __init__(
        self,
        client: KMSClient,
        key_id: str,
        *,
        driver_name: str | None = None,
    ) -> None:
        self._client = client
        self._key_id = key_id
        if driver_name is not None:
            self.driver_name = driver_name

    @classmethod
    def from_settings(cls, settings: Settings) -> AwsKeyProvider:
        import boto3

        client = boto3.client("kms", region_name=settings.AWS_REGION)
        return cls(client, settings.AEGIS_KMS_KEY_ID)

    @property
    def key_id(self) -> str:
        return self._key_id

    async def generate_data_key(self, ctx: EncryptionContext) -> DataKey:
        try:
            resp = self._client.generate_data_key(
                KeyId=self._key_id,
                KeySpec="AES_256",
                EncryptionContext=ctx.as_kms_dict(),
            )
        except (BotoCoreError, ClientError) as exc:
            msg = "無法產生資料金鑰"
            raise KmsError("generate_data_key", msg) from exc
        return DataKey(plaintext=resp["Plaintext"], wrapped=resp["CiphertextBlob"])

    async def decrypt_data_key(self, wrapped: bytes, ctx: EncryptionContext) -> bytes:
        try:
            resp = self._client.decrypt(
                CiphertextBlob=wrapped,
                EncryptionContext=ctx.as_kms_dict(),
            )
        except (BotoCoreError, ClientError) as exc:
            msg = "無法解開資料金鑰"
            raise KmsError("decrypt_data_key", msg) from exc
        return resp["Plaintext"]

    async def rotate(self, key_id: str) -> str:
        """建立新金鑰並把 alias 指過去；舊密文仍可用原 ciphertext 解開。"""
        try:
            created = self._client.create_key(
                KeyUsage="ENCRYPT_DECRYPT",
                KeySpec="SYMMETRIC_DEFAULT",
            )
            new_id = created["KeyMetadata"]["KeyId"]
            alias = key_id if key_id.startswith("alias/") else f"alias/{key_id}"
            try:
                self._client.update_alias(AliasName=alias, TargetKeyId=new_id)
            except ClientError:
                self._client.create_alias(AliasName=alias, TargetKeyId=new_id)
        except (BotoCoreError, ClientError) as exc:
            msg = "金鑰輪替失敗"
            raise KmsError("rotate", msg) from exc
        return new_id

    async def hmac_sha256(self, key_id: str, message: bytes) -> bytes:
        """決定論 MAC：優先 GenerateMac；對稱金鑰則快取一顆 DEK 當 HMAC 鹽。"""
        try:
            resp = self._client.generate_mac(
                KeyId=key_id,
                Message=message,
                MacAlgorithm="HMAC_SHA_256",
            )
            return resp["Mac"]
        except (BotoCoreError, ClientError, KeyError):
            _LOG.debug("GenerateMac 不可用，改用行程內快取的對稱 DEK 當 HMAC 鹽")
        cached = _HMAC_CACHE.get(key_id)
        if cached is None:
            try:
                data_key = self._client.generate_data_key(KeyId=key_id, KeySpec="AES_256")
            except (BotoCoreError, ClientError) as exc:
                msg = "無法取得假名化 HMAC 金鑰"
                raise KmsError("hmac_key", msg) from exc
            cached = data_key["Plaintext"]
            _HMAC_CACHE[key_id] = cached
        return hmac.new(cached, message, hashlib.sha256).digest()
