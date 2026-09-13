"""七個契約指標。名稱與標籤不得更名，模組 F 的告警直接依賴它們。"""

from __future__ import annotations

import time
from collections.abc import Awaitable, Callable

from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

from app.errors import KmsError

KMS_ENCRYPT = Counter(
    "aegis_kms_encrypt_total",
    "資料金鑰產生次數",
    ["driver", "key_id"],
)
KMS_DECRYPT = Counter(
    "aegis_kms_decrypt_total",
    "資料金鑰解密次數（外洩偵測主指標）",
    ["driver", "key_id", "subject"],
)
KMS_OPERATION_DURATION = Histogram(
    "aegis_kms_operation_duration_seconds",
    "KMS 呼叫延遲",
    ["driver", "operation"],
)
KMS_ERRORS = Counter(
    "aegis_kms_errors_total",
    "KMS 錯誤",
    ["driver", "operation"],
)
MASKING_APPLIED = Counter(
    "aegis_masking_applied_total",
    "成功遮罩的欄位數",
    ["field_type"],
)
MASKING_BYPASS = Counter(
    "aegis_masking_bypass_total",
    "遮罩失效；任何非零都應告警",
    ["field_type", "reason"],
)
CHAIN_CALLS = Counter(
    "aegis_chain_calls_total",
    "合約呼叫次數",
    ["method", "status"],
)


async def observe_kms[T](
    driver: str,
    operation: str,
    func: Callable[[], Awaitable[T]],
) -> T:
    """量測單一 KMS 操作的延遲，失敗時累加 errors 再拋出穩定錯誤。"""
    started = time.perf_counter()
    try:
        return await func()
    except KmsError:
        KMS_ERRORS.labels(driver=driver, operation=operation).inc()
        raise
    except Exception as exc:
        KMS_ERRORS.labels(driver=driver, operation=operation).inc()
        msg = "KMS 操作失敗"
        raise KmsError(operation, msg) from exc
    finally:
        KMS_OPERATION_DURATION.labels(driver=driver, operation=operation).observe(
            time.perf_counter() - started
        )


def render_metrics() -> tuple[bytes, str]:
    return generate_latest(), CONTENT_TYPE_LATEST
