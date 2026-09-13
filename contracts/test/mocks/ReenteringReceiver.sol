// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CarbonCredit} from "../../src/CarbonCredit.sol";

/// @dev 惡意 ERC-1155 接收者：在 onERC1155Received 再入 mint 或 retire。
contract ReenteringReceiver {
    CarbonCredit public carbon;
    uint256 public projectId;

    enum Attack {
        None,
        Mint,
        Retire
    }

    Attack public attack;

    function configure(CarbonCredit carbon_, uint256 projectId_, Attack attack_) external {
        carbon = carbon_;
        projectId = projectId_;
        attack = attack_;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4) {
        if (attack == Attack.Mint) {
            carbon.mintBatch(address(this), projectId, 1, bytes32(uint256(1)));
        } else if (attack == Attack.Retire) {
            carbon.retire(projectId, 1, "reenter");
        }
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }
}
