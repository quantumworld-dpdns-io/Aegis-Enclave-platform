"""Prometheus 指標與結構化稽核日誌。名稱對齊 CONTRACT.md 第 3、4 節。"""

from app.observability.logging import bind_request, configure_logging, get_logger
from app.observability.metrics import (
    CHAIN_CALLS,
    KMS_DECRYPT,
    KMS_ENCRYPT,
    KMS_ERRORS,
    KMS_OPERATION_DURATION,
    MASKING_APPLIED,
    MASKING_BYPASS,
    observe_kms,
    render_metrics,
)

__all__ = [
    "CHAIN_CALLS",
    "KMS_DECRYPT",
    "KMS_ENCRYPT",
    "KMS_ERRORS",
    "KMS_OPERATION_DURATION",
    "MASKING_APPLIED",
    "MASKING_BYPASS",
    "bind_request",
    "configure_logging",
    "get_logger",
    "observe_kms",
    "render_metrics",
]
