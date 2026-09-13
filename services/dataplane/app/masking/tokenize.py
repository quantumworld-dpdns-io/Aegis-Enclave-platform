"""HMAC-SHA256 決定論 tokenization。金鑰來自 AEGIS_PSEUDONYM_SALT_KEY_ID，不用來假名化 subject。"""

from __future__ import annotations

from app.kms.base import KeyProvider

TOKEN_PREFIX = "tok_"  # noqa: S105 — 假名標頭，不是密鑰
TOKEN_HEX_LEN = 16


class Tokenizer:
    """同一輸入永遠同一 token，日誌仍可 join，但沒有金鑰無法反推。"""

    def __init__(self, provider: KeyProvider, salt_key_id: str) -> None:
        self._provider = provider
        self._salt_key_id = salt_key_id

    async def token(self, value: str) -> str:
        digest = await self._provider.hmac_sha256(self._salt_key_id, value.encode("utf-8"))
        return f"{TOKEN_PREFIX}{digest.hex()[:TOKEN_HEX_LEN]}"
