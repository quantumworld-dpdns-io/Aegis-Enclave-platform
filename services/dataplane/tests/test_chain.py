"""鏈上客戶端：local.json 缺失必須降級，不可讓程序崩潰。"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from app.chain.client import ChainClient, find_deployment_file, load_carbon_address
from app.config import Settings
from app.errors import ChainUnavailableError


def test_missing_deployment_is_none(tmp_path: Path) -> None:
    assert find_deployment_file(tmp_path) is None
    settings = Settings(AEGIS_CARBON_CONTRACT_ADDR="")
    assert load_carbon_address(settings, start=tmp_path) is None


def test_env_address_wins(tmp_path: Path) -> None:
    settings = Settings(AEGIS_CARBON_CONTRACT_ADDR="0xabc")
    assert load_carbon_address(settings, start=tmp_path) == "0xabc"


def test_reads_local_json_when_present(tmp_path: Path) -> None:
    dest = tmp_path / "contracts" / "deployments"
    dest.mkdir(parents=True)
    (dest / "local.json").write_text(
        json.dumps(
            {
                "chainId": 31337,
                "CarbonCredit": "0x1111111111111111111111111111111111111111",
                "RetirementRegistry": "0x2222222222222222222222222222222222222222",
            }
        ),
        encoding="utf-8",
    )
    settings = Settings(AEGIS_CARBON_CONTRACT_ADDR="")
    addr = load_carbon_address(settings, start=tmp_path)
    assert addr == "0x1111111111111111111111111111111111111111"


@pytest.mark.asyncio
async def test_retire_without_address_raises() -> None:
    client = ChainClient(Settings(), address=None)
    assert client.available is False
    with pytest.raises(ChainUnavailableError) as exc:
        await client.retire(1, 10, "sub_aa")
    assert exc.value.code == "chain_unconfigured"
