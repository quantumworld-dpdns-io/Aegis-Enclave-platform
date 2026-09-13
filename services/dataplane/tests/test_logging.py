"""日誌不得出現原始 PII、金鑰材料或完整 JWT。"""

from __future__ import annotations

import io
import json

import structlog
from app.observability.logging import configure_logging, get_logger


def test_log_redacts_pii_and_secrets() -> None:
    buffer = io.StringIO()
    configure_logging("info")
    structlog.configure(
        processors=[
            structlog.processors.add_log_level,
            structlog.processors.JSONRenderer(),
        ],
        logger_factory=structlog.PrintLoggerFactory(file=buffer),
        cache_logger_on_first_use=False,
    )
    # 重新套用正式 processor，確保 redact 有跑到。
    from app.observability.logging import _add_service, _iso_now, _redact

    structlog.configure(
        processors=[
            structlog.processors.add_log_level,
            _iso_now,
            _add_service,
            _redact,
            structlog.processors.JSONRenderer(),
        ],
        logger_factory=structlog.PrintLoggerFactory(file=buffer),
        cache_logger_on_first_use=False,
    )
    log = get_logger()
    log.info(
        "record.read",
        subject="sub_deadbeefcafebabe",
        national_id="A123456789",
        dek="aa" * 32,
        jwt="eyJhbGciOiJSUzI1NiJ9.payload.sig",
    )
    line = buffer.getvalue()
    payload = json.loads(line)
    assert "A123456789" not in line
    assert payload["national_id"] == "[redacted]"
    assert payload["dek"] == "[redacted]"
    assert payload["jwt"] == "[redacted]"
    assert payload["subject"] == "sub_deadbeefcafebabe"
    assert payload["service"] == "dataplane"
    assert "ts" in payload
