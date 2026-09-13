// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {RetirementRegistry} from "../src/RetirementRegistry.sol";
import {BaseTest} from "./Base.t.sol";

contract RetirementRegistryTest is BaseTest {
    function test_ConstructorRevertsOnZeroAdmin() public {
        vm.expectRevert(RetirementRegistry.InvalidAdmin.selector);
        new RetirementRegistry(address(0));
    }

    function test_ConstructorGrantsAdmin() public view {
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin));
        assertFalse(registry.hasRole(registry.RECORDER_ROLE(), admin));
        assertTrue(registry.hasRole(registry.RECORDER_ROLE(), address(carbon)));
    }

    function test_RecordRetirementRevertsForNonRecorder() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, registry.RECORDER_ROLE()
            )
        );
        vm.prank(stranger);
        registry.recordRetirement(1, holder, 1, "Aegis");
    }

    function test_RecordRetirementRevertsOnZeroAmount() public {
        vm.prank(address(carbon));
        vm.expectRevert(RetirementRegistry.InvalidAmount.selector);
        registry.recordRetirement(1, holder, 0, "Aegis");
    }

    function test_RecordRetirementRevertsOnZeroAccount() public {
        vm.prank(address(carbon));
        vm.expectRevert(RetirementRegistry.InvalidAccount.selector);
        registry.recordRetirement(1, address(0), 1, "Aegis");
    }

    function test_RecordRetirementRevertsOnEmptyBeneficiary() public {
        vm.prank(address(carbon));
        vm.expectRevert(RetirementRegistry.InvalidBeneficiary.selector);
        registry.recordRetirement(1, holder, 1, "");
    }

    function test_RecordRetirementAppendsAndIsIrreversible() public {
        vm.startPrank(address(carbon));
        registry.recordRetirement(9, holder, 4, "one");
        registry.recordRetirement(9, stranger, 6, "two");
        vm.stopPrank();

        assertEq(registry.retirementCount(), 2);
        assertEq(registry.totalRetired(9), 10);

        (uint256 projectId, address account, uint256 amount, string memory beneficiary, uint256 timestamp) =
            registry.getRetirement(1);
        assertEq(projectId, 9);
        assertEq(account, stranger);
        assertEq(amount, 6);
        assertEq(beneficiary, "two");
        assertEq(timestamp, block.timestamp);

        // 沒有 delete / update；只能繼續附加。
        vm.prank(address(carbon));
        registry.recordRetirement(9, holder, 1, "three");
        assertEq(registry.retirementCount(), 3);
        assertEq(registry.totalRetired(9), 11);
        (,, uint256 firstAmount,,) = registry.getRetirement(0);
        assertEq(firstAmount, 4);
    }

    function test_GetRetirementRevertsOnUnknownId() public {
        vm.expectRevert();
        registry.getRetirement(0);
    }

    function test_TotalRetiredIndependentPerProject() public {
        vm.startPrank(address(carbon));
        registry.recordRetirement(1, holder, 3, "a");
        registry.recordRetirement(2, holder, 5, "b");
        vm.stopPrank();
        assertEq(registry.totalRetired(1), 3);
        assertEq(registry.totalRetired(2), 5);
        assertEq(registry.totalRetired(3), 0);
    }
}
