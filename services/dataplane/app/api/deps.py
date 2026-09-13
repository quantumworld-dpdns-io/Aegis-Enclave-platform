"""從 gateway 標頭取出已假名化的 subject 與角色。資料面不再對 subject 做 HMAC。"""

from __future__ import annotations

import uuid
from typing import Annotated

from fastapi import Header

from app.masking.policy import MaskingRole, parse_role

ANONYMOUS_SUBJECT = "sub_anonymous"


def request_id_header(
    x_aegis_request_id: Annotated[str | None, Header(alias="X-Aegis-Request-ID")] = None,
) -> str:
    return x_aegis_request_id or str(uuid.uuid4())


def subject_header(
    x_aegis_subject: Annotated[str | None, Header(alias="X-Aegis-Subject")] = None,
) -> str:
    # 信任 gateway 已寫入 sub_ + HMAC hex[:16]；缺省用固定假名以免指標標籤爆炸。
    if x_aegis_subject:
        return x_aegis_subject
    return ANONYMOUS_SUBJECT


def role_header(
    x_aegis_role: Annotated[str | None, Header(alias="X-Aegis-Role")] = None,
) -> MaskingRole:
    return parse_role(x_aegis_role)
