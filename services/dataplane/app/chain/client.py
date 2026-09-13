"""經 web3 呼叫 CarbonCredit.retire。合約 ABI 對齊 CONTRACT.md 第 7 節。"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from app.config import Settings
from app.errors import ChainUnavailableError
from app.observability.logging import get_logger
from app.observability.metrics import CHAIN_CALLS

# 只列 dataplane 會呼叫的函式與對帳事件，避免把整份 ABI 綁死在部署細節。
CARBON_ABI: list[dict[str, Any]] = [
    {
        "type": "function",
        "name": "retire",
        "stateMutability": "nonpayable",
        "inputs": [
            {"name": "projectId", "type": "uint256"},
            {"name": "amount", "type": "uint256"},
            {"name": "beneficiary", "type": "string"},
        ],
        "outputs": [],
    },
    {
        "type": "function",
        "name": "totalRetired",
        "stateMutability": "view",
        "inputs": [{"name": "projectId", "type": "uint256"}],
        "outputs": [{"name": "", "type": "uint256"}],
    },
    {
        "type": "event",
        "name": "CreditsRetired",
        "inputs": [
            {"name": "projectId", "type": "uint256", "indexed": True},
            {"name": "by", "type": "address", "indexed": True},
            {"name": "amount", "type": "uint256", "indexed": False},
            {"name": "beneficiary", "type": "string", "indexed": False},
        ],
    },
]


def find_deployment_file(start: Path | None = None) -> Path | None:
    """從指定根或 cwd / 套件位置往上找 contracts/deployments/local.json。"""
    roots = [start] if start is not None else [Path.cwd(), *Path(__file__).resolve().parents]
    seen: set[Path] = set()
    for root in roots:
        for parent in (root, *root.parents):
            if parent in seen:
                continue
            seen.add(parent)
            candidate = parent / "contracts" / "deployments" / "local.json"
            if candidate.is_file():
                return candidate
    return None


def load_carbon_address(settings: Settings, start: Path | None = None) -> str | None:
    if settings.AEGIS_CARBON_CONTRACT_ADDR:
        return settings.AEGIS_CARBON_CONTRACT_ADDR
    path = find_deployment_file(start)
    if path is None:
        return None
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        get_logger().warning("chain.deployment_unreadable")
        return None
    addr = payload.get("CarbonCredit")
    if isinstance(addr, str) and addr:
        return addr
    return None


_UNSET = object()


class ChainClient:
    """對 Anvil 的薄封裝。任何連線或設定問題都轉成 ChainUnavailableError。"""

    def __init__(
        self,
        settings: Settings,
        *,
        address: str | object | None = _UNSET,
    ) -> None:
        self._settings = settings
        # address=None 表示測試強制未設定；省略參數才去掃 local.json。
        if address is _UNSET:
            self._address = load_carbon_address(settings)
        else:
            self._address = address if isinstance(address, str) and address else None
        self._w3: Any = None

    @property
    def available(self) -> bool:
        return bool(self._address)

    def _web3(self) -> Any:
        if self._w3 is not None:
            return self._w3
        if not self._address:
            msg = "碳權合約尚未就緒"
            raise ChainUnavailableError("chain_unconfigured", msg)
        try:
            from web3 import Web3

            provider = Web3.HTTPProvider(
                self._settings.AEGIS_CHAIN_RPC_URL,
                request_kwargs={"timeout": 5},
            )
            w3 = Web3(provider)
            if not w3.is_connected():
                msg = "鏈上節點不可用"
                raise ChainUnavailableError("chain_unreachable", msg)
        except ChainUnavailableError:
            raise
        except Exception as exc:
            msg = "鏈上節點不可用"
            raise ChainUnavailableError("chain_unreachable", msg) from exc
        self._w3 = w3
        return w3

    async def retire(self, project_id: int, amount: int, beneficiary: str) -> str:
        if not self.available:
            CHAIN_CALLS.labels(method="retire", status="unavailable").inc()
            msg = "碳權合約尚未就緒"
            raise ChainUnavailableError("chain_unconfigured", msg)
        try:
            w3 = self._web3()
            address = w3.to_checksum_address(self._address)
            contract = w3.eth.contract(address=address, abi=CARBON_ABI)
            accounts = w3.eth.accounts
            if not accounts:
                msg = "鏈上沒有可用帳戶"
                raise ChainUnavailableError("chain_no_account", msg)
            tx_hash = contract.functions.retire(project_id, amount, beneficiary).transact(
                {"from": accounts[0]}
            )
            receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
        except ChainUnavailableError:
            CHAIN_CALLS.labels(method="retire", status="error").inc()
            raise
        except Exception as exc:
            CHAIN_CALLS.labels(method="retire", status="error").inc()
            msg = "碳權退役呼叫失敗"
            raise ChainUnavailableError("chain_call_failed", msg) from exc
        CHAIN_CALLS.labels(method="retire", status="ok").inc()
        tx_hex: str = receipt["transactionHash"].hex()
        return tx_hex
