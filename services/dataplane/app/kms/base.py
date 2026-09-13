"""KeyProvider 抽象與金鑰用途綁定的 encryption context。

EncryptionContext 會同時送進 KMS encryption context 與 AES-GCM AAD，
兩者必須完全一致，否則密文被搬到別的 tenant / purpose 時會直接失敗。
"""

from __future__ import annotations

from collections.abc import Iterator
from typing import Protocol, runtime_checkable

from pydantic import BaseModel, Field

AES_256_KEY_BYTES = 32


class EncryptionContext(BaseModel):
    """對應 AWS KMS encryption context；所有值必須是字串。"""

    record_id: str = Field(min_length=1)
    tenant: str = Field(min_length=1)
    purpose: str = Field(default="vault", min_length=1)

    def as_kms_dict(self) -> dict[str, str]:
        """KMS 與信封 aad 共用的字典，鍵順序固定以便對帳。"""
        return {
            "record_id": self.record_id,
            "tenant": self.tenant,
            "purpose": self.purpose,
        }

    def canonical_aad(self) -> bytes:
        """AES-GCM additional authenticated data：穩定序列化後的 aad。"""
        from app.crypto.canonical import dumps_canonical

        return dumps_canonical(self.as_kms_dict())


class DataKey:
    """同時持有明文 DEK 與 wrapped DEK。

    明文以 bytearray 保存，方便 zeroize 覆寫。Python 的 GC 與字串 intern
    無法保證實體記憶體被抹除，這是解譯器層級的已知限制，不是這層能補的。
    """

    def __init__(self, plaintext: bytes, wrapped: bytes) -> None:
        if len(plaintext) != AES_256_KEY_BYTES:
            msg = "DEK 必須是 32 bytes（AES-256）"
            raise ValueError(msg)
        self._plaintext = bytearray(plaintext)
        self.wrapped = wrapped

    @property
    def plaintext(self) -> bytes:
        return bytes(self._plaintext)

    def zeroize(self) -> None:
        """盡力覆寫明文緩衝；無法保證複本已被 GC 回收。"""
        for index in range(len(self._plaintext)):
            self._plaintext[index] = 0

    def __enter__(self) -> DataKey:
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        traceback: object,
    ) -> None:
        self.zeroize()

    def __iter__(self) -> Iterator[bytes]:
        yield self.plaintext
        yield self.wrapped


@runtime_checkable
class KeyProvider(Protocol):
    """三個 driver 必須滿足的行為契約。"""

    @property
    def driver_name(self) -> str: ...

    @property
    def key_id(self) -> str: ...

    async def generate_data_key(self, ctx: EncryptionContext) -> DataKey: ...

    async def decrypt_data_key(self, wrapped: bytes, ctx: EncryptionContext) -> bytes: ...

    async def rotate(self, key_id: str) -> str: ...

    async def hmac_sha256(self, key_id: str, message: bytes) -> bytes: ...
