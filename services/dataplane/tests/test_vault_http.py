"""Vault HTTP backend：用 mock 傳輸，不連真實 Vault。"""

from __future__ import annotations

import base64

import httpx
import pytest
from app.errors import KmsError
from app.kms.vault import HttpxVaultBackend


def _handler(request: httpx.Request) -> httpx.Response:
    path = request.url.path
    if path.endswith("/encrypt/aegis-master"):
        return httpx.Response(200, json={"data": {"ciphertext": "vault:v1:abc"}})
    if path.endswith("/decrypt/aegis-master"):
        return httpx.Response(
            200,
            json={"data": {"plaintext": base64.b64encode(b"x" * 32).decode()}},
        )
    if "/hmac/" in path:
        mac = base64.b64encode(b"m" * 32).decode()
        return httpx.Response(200, json={"data": {"hmac": f"vault:v1:{mac}"}})
    if path.endswith("/rotate"):
        return httpx.Response(204)
    return httpx.Response(500, json={"errors": ["no"]})


@pytest.mark.asyncio
async def test_http_vault_success() -> None:
    transport = httpx.MockTransport(_handler)

    class _Client(httpx.AsyncClient):
        def __init__(self, **kwargs: object) -> None:
            super().__init__(transport=transport, timeout=5.0)

    import app.kms.vault as vault_mod

    original = vault_mod.httpx.AsyncClient
    vault_mod.httpx.AsyncClient = _Client  # type: ignore[method-assign,assignment]
    try:
        backend = HttpxVaultBackend("http://vault.example:8200", "dev-token")
        wrapped = await backend.encrypt("aegis-master", b"p" * 32, b"ctx")
        assert wrapped == b"vault:v1:abc"
        plain = await backend.decrypt("aegis-master", wrapped, b"ctx")
        assert plain == b"x" * 32
        mac = await backend.hmac_sha256("aegis-master", b"msg")
        assert mac == b"m" * 32
        assert await backend.rotate("aegis-master") == "aegis-master"
    finally:
        vault_mod.httpx.AsyncClient = original


@pytest.mark.asyncio
async def test_http_vault_error() -> None:
    def boom(request: httpx.Request) -> httpx.Response:
        return httpx.Response(500)

    transport = httpx.MockTransport(boom)

    class _Client(httpx.AsyncClient):
        def __init__(self, **kwargs: object) -> None:
            super().__init__(transport=transport, timeout=5.0)

    import app.kms.vault as vault_mod

    original = vault_mod.httpx.AsyncClient
    vault_mod.httpx.AsyncClient = _Client  # type: ignore[method-assign,assignment]
    try:
        backend = HttpxVaultBackend("http://vault.example:8200", "dev-token")
        with pytest.raises(KmsError):
            await backend.encrypt("aegis-master", b"p" * 32, b"ctx")
    finally:
        vault_mod.httpx.AsyncClient = original
