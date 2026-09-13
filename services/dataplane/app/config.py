"""從環境變數載入設定。欄位名稱對齊 docs/CONTRACT.md 第 5 節，不可擅自更名。"""

from typing import Literal

from pydantic_settings import BaseSettings, SettingsConfigDict

KmsDriver = Literal["localstack", "vault", "aws"]


class Settings(BaseSettings):
    """資料面執行期設定。預設值必須與契約第 5 節一致。"""

    model_config = SettingsConfigDict(
        env_file=None,
        extra="ignore",
        case_sensitive=True,
    )

    AEGIS_KMS_DRIVER: KmsDriver = "localstack"
    AEGIS_KMS_KEY_ID: str = "alias/aegis-master"
    AEGIS_KMS_ENDPOINT: str = "http://localstack.aegis.svc.cluster.local:4566"
    AEGIS_VAULT_ADDR: str = "http://vault.aegis.svc.cluster.local:8200"
    AEGIS_VAULT_TOKEN: str = ""
    AEGIS_VAULT_TRANSIT_KEY: str = "aegis-master"
    AWS_REGION: str = "ap-northeast-1"
    # 只用於 PII 欄位 tokenization，與 gateway 的 subject 假名鹽值分開。
    AEGIS_PSEUDONYM_SALT_KEY_ID: str = "alias/aegis-pseudonym"
    AEGIS_CHAIN_RPC_URL: str = "http://anvil.aegis.svc.cluster.local:8545"
    AEGIS_CARBON_CONTRACT_ADDR: str = ""
    AEGIS_LOG_LEVEL: str = "info"
