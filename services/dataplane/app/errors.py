"""資料面內部錯誤。對外只暴露穩定的 code，避免把 KMS / 鏈上例外原文回給呼叫端。"""


class DataplaneError(Exception):
    """所有可預期業務錯誤的基底。"""

    def __init__(self, code: str, message: str) -> None:
        self.code = code
        self.message = message
        super().__init__(message)


class EnvelopeError(DataplaneError):
    """密文信封完整性或格式失敗（含 AAD 綁定被破壞）。"""


class KmsError(DataplaneError):
    """KMS / Transit 呼叫失敗。"""


class RecordNotFoundError(DataplaneError):
    """指定紀錄不存在。"""


class ChainUnavailableError(DataplaneError):
    """合約位址未就緒或 RPC 不可用；必須 graceful degrade，不可讓程序崩潰。"""
