"""FastAPI 進入點。只掛契約第 2 節路由；關閉 /docs 以免增加 L7 攻擊面。"""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from app.api.routes import router
from app.api.schemas import ErrorResponse
from app.chain.client import ChainClient
from app.config import Settings
from app.crypto.store import RecordStore
from app.errors import (
    ChainUnavailableError,
    DataplaneError,
    EnvelopeError,
    KmsError,
    RecordNotFoundError,
)
from app.kms.base import KeyProvider
from app.kms.factory import build_key_provider
from app.masking.tokenize import Tokenizer
from app.observability.logging import configure_logging, get_logger


class AppState:
    """集中放執行期相依，避免 handler 直接 new 出 KMS / 儲存。"""

    def __init__(
        self,
        settings: Settings,
        *,
        provider: KeyProvider | None = None,
        store: RecordStore | None = None,
        tokenizer: Tokenizer | None = None,
        chain: ChainClient | None = None,
    ) -> None:
        self.settings = settings
        self.provider = provider or build_key_provider(settings)
        self.store = store or RecordStore()
        self.tokenizer = tokenizer or Tokenizer(self.provider, settings.AEGIS_PSEUDONYM_SALT_KEY_ID)
        self.chain = chain or ChainClient(settings)


def create_app(
    settings: Settings | None = None,
    *,
    state: AppState | None = None,
) -> FastAPI:
    cfg = settings or Settings()

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        configure_logging(cfg.AEGIS_LOG_LEVEL)
        runtime = state or AppState(cfg)
        app.state.settings = runtime.settings
        app.state.provider = runtime.provider
        app.state.store = runtime.store
        app.state.tokenizer = runtime.tokenizer
        app.state.chain = runtime.chain
        get_logger().info(
            "app.start",
            driver=runtime.provider.driver_name,
            chain_ready=runtime.chain.available,
        )
        yield

    app = FastAPI(
        title="aegis-dataplane",
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
        lifespan=lifespan,
    )
    # 若測試直接注入 state，lifespan 仍會覆寫成同一份物件。
    if state is not None:
        app.state.provider = state.provider
        app.state.store = state.store
        app.state.tokenizer = state.tokenizer
        app.state.chain = state.chain
        app.state.settings = state.settings

    app.include_router(router)
    _register_errors(app)
    return app


def _register_errors(app: FastAPI) -> None:
    @app.exception_handler(RecordNotFoundError)
    async def _not_found(_: Request, exc: RecordNotFoundError) -> JSONResponse:
        return JSONResponse(
            status_code=404,
            content=ErrorResponse(error=exc.message, code=exc.code).model_dump(),
        )

    @app.exception_handler(EnvelopeError)
    async def _envelope(_: Request, exc: EnvelopeError) -> JSONResponse:
        return JSONResponse(
            status_code=400,
            content=ErrorResponse(error=exc.message, code=exc.code).model_dump(),
        )

    @app.exception_handler(KmsError)
    async def _kms(_: Request, exc: KmsError) -> JSONResponse:
        get_logger().error("kms.error", code=exc.code)
        return JSONResponse(
            status_code=502,
            content=ErrorResponse(error="金鑰作業失敗", code=exc.code).model_dump(),
        )

    @app.exception_handler(ChainUnavailableError)
    async def _chain(_: Request, exc: ChainUnavailableError) -> JSONResponse:
        return JSONResponse(
            status_code=503,
            content=ErrorResponse(error=exc.message, code=exc.code).model_dump(),
        )

    @app.exception_handler(DataplaneError)
    async def _generic(_: Request, exc: DataplaneError) -> JSONResponse:
        return JSONResponse(
            status_code=400,
            content=ErrorResponse(error=exc.message, code=exc.code).model_dump(),
        )


app = create_app()
