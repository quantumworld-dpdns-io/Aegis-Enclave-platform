"""結構化 JSON 日誌。subject 必須已是 gateway 傳來的假名，禁止再寫入原始 PII。"""

from __future__ import annotations

import logging
import re
from datetime import UTC, datetime
from typing import Any

import structlog
from structlog.typing import EventDict, WrappedLogger

from app.masking.detect import looks_like_pii

_SERVICE = "dataplane"

# 常見金鑰材料欄位：即使呼叫端誤傳也要在離開程序前抹掉。
_SECRET_KEYS = frozenset(
    {
        "plaintext",
        "dek",
        "wrapped_dek",
        "authorization",
        "jwt",
        "token",
        "password",
        "secret",
        "national_id",
        "card_number",
        "iban",
        "holder_name",
        "email",
        "phone",
    }
)
_HEX_KEY = re.compile(r"^[0-9a-fA-F]{32,}$")


def _iso_now(_: WrappedLogger, __: str, event_dict: EventDict) -> EventDict:
    event_dict["ts"] = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    return event_dict


def _add_service(_: WrappedLogger, __: str, event_dict: EventDict) -> EventDict:
    event_dict.setdefault("service", _SERVICE)
    return event_dict


def _redact(_: WrappedLogger, __: str, event_dict: EventDict) -> EventDict:
    """最後一道保險：鍵名敏感或值看起來像 PII / 金鑰時改寫成 [redacted]。"""
    for key, value in list(event_dict.items()):
        if key.lower() in _SECRET_KEYS:
            event_dict[key] = "[redacted]"
            continue
        if isinstance(value, str) and (looks_like_pii(value) or _HEX_KEY.fullmatch(value)):
            event_dict[key] = "[redacted]"
    return event_dict


def configure_logging(level: str = "info") -> None:
    numeric = getattr(logging, level.upper(), logging.INFO)
    logging.basicConfig(level=numeric, format="%(message)s")
    structlog.configure(
        processors=[
            structlog.contextvars.merge_contextvars,
            structlog.processors.add_log_level,
            _iso_now,
            _add_service,
            _redact,
            structlog.processors.JSONRenderer(),
        ],
        wrapper_class=structlog.make_filtering_bound_logger(numeric),
        context_class=dict,
        logger_factory=structlog.PrintLoggerFactory(),
        cache_logger_on_first_use=True,
    )


def get_logger() -> Any:
    return structlog.get_logger()


def bind_request(
    *,
    request_id: str,
    subject: str,
    resource: str,
    trace_id: str | None = None,
) -> None:
    structlog.contextvars.clear_contextvars()
    structlog.contextvars.bind_contextvars(
        request_id=request_id,
        subject=subject,
        resource=resource,
        trace_id=trace_id or request_id,
    )
