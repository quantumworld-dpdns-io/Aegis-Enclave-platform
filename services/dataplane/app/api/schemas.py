"""API 輸入／輸出結構。Handler 不直接暴露 KMS 或儲存層的內部型別。"""

from pydantic import BaseModel, Field


class RecordCreateRequest(BaseModel):
    tenant: str = Field(min_length=1, max_length=64)
    holder_name: str = Field(min_length=1, max_length=128)
    national_id: str | None = None
    iban: str | None = None
    email: str | None = None
    phone: str | None = None
    card_number: str | None = None
    amount: str | None = None


class RecordCreateResponse(BaseModel):
    record_id: str
    tenant: str


class RecordReadResponse(BaseModel):
    record_id: str
    tenant: str
    holder_name: str | None = None
    national_id: str | None = None
    iban: str | None = None
    email: str | None = None
    phone: str | None = None
    card_number: str | None = None
    amount: str | None = None


class RetireRequest(BaseModel):
    project_id: int = Field(ge=0, alias="projectId")
    amount: int = Field(gt=0)
    beneficiary: str | None = None

    model_config = {"populate_by_name": True}


class RetireResponse(BaseModel):
    tx_hash: str
    project_id: int
    amount: int


class HealthResponse(BaseModel):
    status: str = "ok"


class ErrorResponse(BaseModel):
    error: str
    code: str
