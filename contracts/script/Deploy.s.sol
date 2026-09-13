// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";

import {CarbonCredit} from "../src/CarbonCredit.sol";
import {RetirementRegistry} from "../src/RetirementRegistry.sol";

/// @title Deploy
/// @notice Deploys `RetirementRegistry` then `CarbonCredit`, grants `RECORDER_ROLE`,
///         and writes `contracts/deployments/local.json` in the CONTRACT.md §7 shape.
contract Deploy is Script {
    /// @dev 本機 Anvil 預設 URI；`{id}` 由 ERC-1155 客戶端替換。
    string internal constant DEFAULT_URI = "https://aegis.local/credits/{id}.json";

    /// @dev 部署產出路徑（相對 contracts/；foundry.toml 已授權讀寫）。
    string internal constant DEPLOYMENT_PATH = "./deployments/local.json";

    /// @notice Deploy both contracts. `msg.sender` (the broadcaster) becomes admin.
    function run() public returns (CarbonCredit carbon, RetirementRegistry registry) {
        // forge script --sender / --private-key 會決定 msg.sender；測試直接呼叫時則是測試合約。
        // 必須用同一個地址 broadcast，否則 grantRole 會變成「部署者 ≠ admin」。
        address admin = msg.sender;
        vm.startBroadcast(admin);

        registry = new RetirementRegistry(admin);
        carbon = new CarbonCredit(admin, address(registry), DEFAULT_URI);
        // CarbonCredit 必須能寫入登記冊，否則 retire() 會在 onlyRole 失敗。
        registry.grantRole(registry.RECORDER_ROLE(), address(carbon));

        vm.stopBroadcast();

        _writeDeployment(address(carbon), address(registry));
    }

    /// @dev 寫入契約規定的 JSON：`{chainId, CarbonCredit, RetirementRegistry}`。
    function _writeDeployment(address carbon, address registry) internal {
        string memory obj = "deployment";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "CarbonCredit", carbon);
        string memory json = vm.serializeAddress(obj, "RetirementRegistry", registry);
        vm.writeJson(json, DEPLOYMENT_PATH);
    }
}
