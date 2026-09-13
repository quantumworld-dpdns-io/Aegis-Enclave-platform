// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CarbonCredit} from "../../src/CarbonCredit.sol";

/// @dev 惡意登記冊：在 recordRetirement 回呼再入 retire，用來驗證 ReentrancyGuard。
contract ReenteringRegistry {
    CarbonCredit public carbon;
    bool public attack;

    function setCarbon(CarbonCredit carbon_) external {
        carbon = carbon_;
    }

    function enableAttack(bool enabled) external {
        attack = enabled;
    }

    function recordRetirement(uint256 projectId, address, uint256, string calldata) external {
        if (attack) {
            attack = false;
            carbon.retire(projectId, 1, "reenter");
        }
    }
}
