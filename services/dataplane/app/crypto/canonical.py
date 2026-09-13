"""穩定 JSON 序列化：aad 必須能同時當 AES-GCM AAD 與 KMS encryption context。"""

from __future__ import annotations

import json
from collections.abc import Mapping


def dumps_canonical(payload: Mapping[str, str]) -> bytes:
    """固定分隔符與鍵排序，避免同一組 aad 因序列化差異而驗證失敗。"""
    return json.dumps(
        dict(payload),
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
