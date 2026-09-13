"""Vault Transit driver。正式走 HTTP；測試注入 in-memory fake，不打外部服務。"""

from __future__ import annotations

import base64
import hashlib
import hmac
import secrets
from typing import Protocol
from urllib.parse import quote

import httpx
from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from app.errors import KmsError
from app.kms.base import AES_256_KEY_BYTES, DataKey, EncryptionContext

_VAULT_NONCE_BYTES = 12
_CONTEXT_MISMATCH = "encryption context 不符"


class VaultBackend(Protocol):
    """Transit 最小介面：encrypt / decrypt / hmac / rotate。"""

    async def encrypt(self, key_name: str, plaintext: bytes, context: bytes) -> bytes: ...

    async def decrypt(self, key_name: str, ciphertext: bytes, context: bytes) -> bytes: ...

    async def hmac_sha256(self, key_name: str, message: bytes) -> bytes: ...

    async def rotate(self, key_name: str) -> str: ...


class FakeVaultBackend:
    """行程內 Transit 替身。wrapped blob 以 AES-GCM 綁 context，模擬金鑰用途綁定。"""

    def __init__(self) -> None:
        self._hmac_keys: dict[str, bytes] = {}
        self._versions: dict[str, int] = {}
        self._masters: dict[tuple[str, int], bytes] = {}

    def _master(self, key_name: str) -> bytes:
        version = self._versions.setdefault(key_name, 1)
        slot = (key_name, version)
        if slot not in self._masters:
            self._masters[slot] = secrets.token_bytes(AES_256_KEY_BYTES)
        return self._masters[slot]

    def _hmac_key(self, key_name: str) -> bytes:
        if key_name not in self._hmac_keys:
            self._hmac_keys[key_name] = secrets.token_bytes(AES_256_KEY_BYTES)
        return self._hmac_keys[key_name]

    async def encrypt(self, key_name: str, plaintext: bytes, context: bytes) -> bytes:
        nonce = secrets.token_bytes(_VAULT_NONCE_BYTES)
        version = self._versions.setdefault(key_name, 1)
        ct = AESGCM(self._master(key_name)).encrypt(nonce, plaintext, context)
        return bytes([version]) + nonce + ct

    async def decrypt(self, key_name: str, ciphertext: bytes, context: bytes) -> bytes:
        if len(ciphertext) < 1 + _VAULT_NONCE_BYTES + 16:
            msg = "wrapped DEK 長度不正確"
            raise KmsError("decrypt_data_key", msg)
        version = ciphertext[0]
        nonce = ciphertext[1 : 1 + _VAULT_NONCE_BYTES]
        body = ciphertext[1 + _VAULT_NONCE_BYTES :]
        master = self._masters.get((key_name, version))
        if master is None:
            msg = "找不到對應版本的 Transit 金鑰"
            raise KmsError("decrypt_data_key", msg)
        try:
            return AESGCM(master).decrypt(nonce, body, context)
        except InvalidTag as exc:
            raise KmsError("decrypt_data_key", _CONTEXT_MISMATCH) from exc

    async def hmac_sha256(self, key_name: str, message: bytes) -> bytes:
        return hmac.new(self._hmac_key(key_name), message, hashlib.sha256).digest()

    async def rotate(self, key_name: str) -> str:
        nxt = self._versions.get(key_name, 1) + 1
        self._versions[key_name] = nxt
        self._masters[(key_name, nxt)] = secrets.token_bytes(AES_256_KEY_BYTES)
        return f"{key_name}:v{nxt}"


class HttpxVaultBackend:
    """對真實 Vault Transit API 的薄封裝。錯誤不回傳 Vault 原文。"""

    def __init__(self, addr: str, token: str) -> None:
        self._addr = addr.rstrip("/")
        self._token = token

    def _headers(self) -> dict[str, str]:
        return {"X-Vault-Token": self._token}

    async def encrypt(self, key_name: str, plaintext: bytes, context: bytes) -> bytes:
        path = f"{self._addr}/v1/transit/encrypt/{quote(key_name)}"
        payload = {
            "plaintext": base64.b64encode(plaintext).decode("ascii"),
            "context": base64.b64encode(context).decode("ascii"),
        }
        try:
            async with httpx.AsyncClient(timeout=5.0) as client:
                resp = await client.post(path, json=payload, headers=self._headers())
                resp.raise_for_status()
                cipher = str(resp.json()["data"]["ciphertext"])
        except (httpx.HTTPError, KeyError, ValueError) as exc:
            msg = "Vault Transit 加密失敗"
            raise KmsError("generate_data_key", msg) from exc
        return cipher.encode("utf-8")

    async def decrypt(self, key_name: str, ciphertext: bytes, context: bytes) -> bytes:
        path = f"{self._addr}/v1/transit/decrypt/{quote(key_name)}"
        payload = {
            "ciphertext": ciphertext.decode("utf-8"),
            "context": base64.b64encode(context).decode("ascii"),
        }
        try:
            async with httpx.AsyncClient(timeout=5.0) as client:
                resp = await client.post(path, json=payload, headers=self._headers())
                resp.raise_for_status()
                plain_b64 = resp.json()["data"]["plaintext"]
        except (httpx.HTTPError, KeyError, ValueError) as exc:
            msg = "Vault Transit 解密失敗"
            raise KmsError("decrypt_data_key", msg) from exc
        return base64.b64decode(plain_b64)

    async def hmac_sha256(self, key_name: str, message: bytes) -> bytes:
        path = f"{self._addr}/v1/transit/hmac/{quote(key_name)}"
        payload = {
            "input": base64.b64encode(message).decode("ascii"),
            "algorithm": "sha2-256",
        }
        try:
            async with httpx.AsyncClient(timeout=5.0) as client:
                resp = await client.post(path, json=payload, headers=self._headers())
                resp.raise_for_status()
                digest = resp.json()["data"]["hmac"]
        except (httpx.HTTPError, KeyError, ValueError) as exc:
            msg = "Vault Transit HMAC 失敗"
            raise KmsError("hmac_key", msg) from exc
        # Vault 回傳 "vault:v1:<base64>"
        token = digest.split(":")[-1]
        return base64.b64decode(token)

    async def rotate(self, key_name: str) -> str:
        path = f"{self._addr}/v1/transit/keys/{quote(key_name)}/rotate"
        try:
            async with httpx.AsyncClient(timeout=5.0) as client:
                resp = await client.post(path, headers=self._headers())
                resp.raise_for_status()
        except httpx.HTTPError as exc:
            msg = "Vault Transit 輪替失敗"
            raise KmsError("rotate", msg) from exc
        return key_name


class VaultKeyProvider:
    """以本地產生 DEK、Transit 只負責 wrap，避免每筆資料都打遠端加解密。"""

    driver_name = "vault"

    def __init__(self, backend: VaultBackend, transit_key: str) -> None:
        self._backend = backend
        self._transit_key = transit_key

    @classmethod
    def from_settings(
        cls,
        addr: str,
        token: str,
        transit_key: str,
        *,
        backend: VaultBackend | None = None,
    ) -> VaultKeyProvider:
        chosen = backend if backend is not None else HttpxVaultBackend(addr, token)
        return cls(chosen, transit_key)

    @property
    def key_id(self) -> str:
        return self._transit_key

    async def generate_data_key(self, ctx: EncryptionContext) -> DataKey:
        plaintext = secrets.token_bytes(AES_256_KEY_BYTES)
        wrapped = await self._backend.encrypt(self._transit_key, plaintext, ctx.canonical_aad())
        return DataKey(plaintext=plaintext, wrapped=wrapped)

    async def decrypt_data_key(self, wrapped: bytes, ctx: EncryptionContext) -> bytes:
        return await self._backend.decrypt(self._transit_key, wrapped, ctx.canonical_aad())

    async def rotate(self, key_id: str) -> str:
        return await self._backend.rotate(key_id)

    async def hmac_sha256(self, key_id: str, message: bytes) -> bytes:
        return await self._backend.hmac_sha256(key_id, message)
