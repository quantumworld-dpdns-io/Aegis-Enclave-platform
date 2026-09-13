// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";
import {RetirementHandler} from "./handlers/RetirementHandler.sol";

/// @dev 全域不變量：總退役量 = 已銷毀量，且單調遞增。
contract RetirementInvariantTest is BaseTest {
    RetirementHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new RetirementHandler(carbon, registry, minter);

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = RetirementHandler.mint.selector;
        selectors[1] = RetirementHandler.retire.selector;
        selectors[2] = RetirementHandler.transfer.selector;

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        excludeContract(address(carbon));
        excludeContract(address(registry));
    }

    /// @notice 每個專案的 totalRetired 等於 handler 記錄的銷毀量。
    function invariant_totalRetiredEqualsBurned() public view {
        for (uint256 i = 0; i < handler.MAX_PROJECTS(); ++i) {
            assertEq(carbon.totalRetired(i), handler.ghostBurned(i), "retired != burned");
            assertEq(carbon.totalRetired(i), handler.ghostRetired(i), "retired != ghost");
            assertEq(registry.totalRetired(i), carbon.totalRetired(i), "registry drift");
        }
    }

    /// @notice 流通量 + 退役量 = 累計鑄造量。
    function invariant_supplyPlusRetiredEqualsMinted() public view {
        for (uint256 i = 0; i < handler.MAX_PROJECTS(); ++i) {
            assertEq(carbon.totalSupply(i) + carbon.totalRetired(i), handler.ghostMinted(i), "conservation");
        }
    }

    /// @notice 退役量相對 handler 上次快照單調遞增（永不回退）。
    function invariant_totalRetiredIsMonotonic() public view {
        for (uint256 i = 0; i < handler.MAX_PROJECTS(); ++i) {
            assertGe(carbon.totalRetired(i), handler.lastSeenRetired(i), "retired decreased");
        }
    }
}
