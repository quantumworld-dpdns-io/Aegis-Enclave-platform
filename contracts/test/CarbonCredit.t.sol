// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {CarbonCredit} from "../src/CarbonCredit.sol";
import {BaseTest} from "./Base.t.sol";
import {ReenteringReceiver} from "./mocks/ReenteringReceiver.sol";
import {ReenteringRegistry} from "./mocks/ReenteringRegistry.sol";

contract CarbonCreditTest is BaseTest {
    function test_ConstructorGrantsAdminRoles() public view {
        assertTrue(carbon.hasRole(carbon.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(carbon.hasRole(carbon.MINTER_ROLE(), admin));
        assertTrue(carbon.hasRole(carbon.PAUSER_ROLE(), admin));
        assertEq(address(carbon.registry()), address(registry));
        assertEq(carbon.uri(1), URI);
    }

    function test_ConstructorRevertsOnZeroAdmin() public {
        vm.expectRevert(CarbonCredit.InvalidAddress.selector);
        new CarbonCredit(address(0), address(registry), URI);
    }

    function test_ConstructorRevertsOnZeroRegistry() public {
        vm.expectRevert(CarbonCredit.InvalidAddress.selector);
        new CarbonCredit(admin, address(0), URI);
    }

    function test_MintBatchCreditsHolderAndEmits() public {
        vm.expectEmit(true, true, false, true, address(carbon));
        emit CarbonCredit.CreditsMinted(7, holder, 100, VERIFICATION);

        vm.prank(minter);
        carbon.mintBatch(holder, 7, 100, VERIFICATION);

        assertEq(carbon.balanceOf(holder, 7), 100);
        assertEq(carbon.totalSupply(7), 100);
        assertEq(carbon.totalRetired(7), 0);
    }

    function test_MintBatchRevertsForNonMinter() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, carbon.MINTER_ROLE()
            )
        );
        vm.prank(stranger);
        carbon.mintBatch(holder, 1, 10, VERIFICATION);
    }

    function test_MintBatchRevertsOnZeroRecipient() public {
        vm.expectRevert(CarbonCredit.InvalidAddress.selector);
        vm.prank(minter);
        carbon.mintBatch(address(0), 1, 10, VERIFICATION);
    }

    function test_MintBatchRevertsOnZeroAmount() public {
        vm.expectRevert(CarbonCredit.InvalidAmount.selector);
        vm.prank(minter);
        carbon.mintBatch(holder, 1, 0, VERIFICATION);
    }

    function test_RetireBurnsAndRecords() public {
        _mint(holder, 3, 50);

        vm.expectEmit(true, true, false, true, address(carbon));
        emit CarbonCredit.CreditsRetired(3, holder, 20, "Aegis DAO");

        vm.prank(holder);
        carbon.retire(3, 20, "Aegis DAO");

        assertEq(carbon.balanceOf(holder, 3), 30);
        assertEq(carbon.totalSupply(3), 30);
        assertEq(carbon.totalRetired(3), 20);
        assertEq(registry.totalRetired(3), 20);
        assertEq(registry.retirementCount(), 1);

        (uint256 projectId, address account, uint256 amount, string memory beneficiary,) = registry.getRetirement(0);
        assertEq(projectId, 3);
        assertEq(account, holder);
        assertEq(amount, 20);
        assertEq(beneficiary, "Aegis DAO");
    }

    function test_RetireRevertsOnZeroAmount() public {
        _mint(holder, 1, 10);
        vm.expectRevert(CarbonCredit.InvalidAmount.selector);
        vm.prank(holder);
        carbon.retire(1, 0, "Aegis");
    }

    function test_RetireRevertsOnEmptyBeneficiary() public {
        _mint(holder, 1, 10);
        vm.expectRevert(CarbonCredit.InvalidBeneficiary.selector);
        vm.prank(holder);
        carbon.retire(1, 1, "");
    }

    function test_RetireRevertsWhenBalanceInsufficient() public {
        _mint(holder, 1, 5);
        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InsufficientBalance.selector, holder, 5, 6, 1));
        vm.prank(holder);
        carbon.retire(1, 6, "Aegis");
    }

    function test_RetirePreventsDoubleSpend() public {
        _mint(holder, 2, 10);
        vm.prank(holder);
        carbon.retire(2, 10, "Aegis");

        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InsufficientBalance.selector, holder, 0, 1, 2));
        vm.prank(holder);
        carbon.retire(2, 1, "Aegis");

        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InsufficientBalance.selector, holder, 0, 1, 2));
        vm.prank(holder);
        carbon.safeTransferFrom(holder, stranger, 2, 1, "");
    }

    function test_RetiredTokensAreIrreversible() public {
        _mint(holder, 4, 8);
        vm.prank(holder);
        carbon.retire(4, 8, "Aegis");

        assertEq(carbon.totalRetired(4), 8);
        assertEq(carbon.totalSupply(4), 0);
        // 沒有 unretire / mint-from-retired 路徑；再鑄是新供給，不會減少已退役量。
        _mint(holder, 4, 3);
        assertEq(carbon.totalRetired(4), 8);
        assertEq(carbon.totalSupply(4), 3);
    }

    function test_PauseBlocksMintRetireAndTransfer() public {
        _mint(holder, 1, 10);

        vm.prank(pauser);
        carbon.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(minter);
        carbon.mintBatch(holder, 1, 1, VERIFICATION);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(holder);
        carbon.retire(1, 1, "Aegis");

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(holder);
        carbon.safeTransferFrom(holder, stranger, 1, 1, "");

        vm.prank(pauser);
        carbon.unpause();

        vm.prank(holder);
        carbon.retire(1, 1, "Aegis");
        assertEq(carbon.totalRetired(1), 1);
    }

    function test_PauseRevertsForNonPauser() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, carbon.PAUSER_ROLE()
            )
        );
        vm.prank(stranger);
        carbon.pause();
    }

    function test_UnpauseRevertsForNonPauser() public {
        vm.prank(pauser);
        carbon.pause();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, carbon.PAUSER_ROLE()
            )
        );
        vm.prank(stranger);
        carbon.unpause();
    }

    function test_SupportsInterface() public view {
        assertTrue(carbon.supportsInterface(type(IERC1155).interfaceId));
        assertTrue(carbon.supportsInterface(type(IAccessControl).interfaceId));
        assertFalse(carbon.supportsInterface(0xffffffff));
    }

    function test_MintReentrancyIsGuarded() public {
        ReenteringReceiver receiver = new ReenteringReceiver();
        bytes32 minterRole = carbon.MINTER_ROLE();
        vm.prank(admin);
        carbon.grantRole(minterRole, address(receiver));
        receiver.configure(carbon, 1, ReenteringReceiver.Attack.Mint);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(minter);
        carbon.mintBatch(address(receiver), 1, 10, VERIFICATION);
    }

    function test_RetireReentrancyDuringMintCallbackIsGuarded() public {
        ReenteringReceiver receiver = new ReenteringReceiver();
        receiver.configure(carbon, 1, ReenteringReceiver.Attack.Retire);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(minter);
        carbon.mintBatch(address(receiver), 1, 10, VERIFICATION);
    }

    function test_RetireReentrancyViaRegistryIsGuarded() public {
        ReenteringRegistry evil = new ReenteringRegistry();
        CarbonCredit isolated = new CarbonCredit(admin, address(evil), URI);
        evil.setCarbon(isolated);
        evil.enableAttack(true);

        vm.startPrank(admin);
        isolated.grantRole(isolated.MINTER_ROLE(), minter);
        vm.stopPrank();

        vm.prank(minter);
        isolated.mintBatch(holder, 1, 10, VERIFICATION);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(holder);
        isolated.retire(1, 2, "Aegis");
    }
}

contract CarbonCreditFuzzTest is BaseTest {
    function testFuzz_MintThenRetireConservesSupply(address to, uint256 projectId, uint256 minted, uint256 retired)
        public
    {
        _assumeEoa(to);
        minted = bound(minted, 1, 1e18);
        retired = bound(retired, 1, minted);

        vm.prank(minter);
        carbon.mintBatch(to, projectId, minted, VERIFICATION);

        vm.prank(to);
        carbon.retire(projectId, retired, "fuzz");

        assertEq(carbon.balanceOf(to, projectId), minted - retired);
        assertEq(carbon.totalSupply(projectId), minted - retired);
        assertEq(carbon.totalRetired(projectId), retired);
        assertEq(registry.totalRetired(projectId), retired);
        assertEq(carbon.totalRetired(projectId) + carbon.totalSupply(projectId), minted);
    }

    function testFuzz_CannotRetireMoreThanBalance(address to, uint256 projectId, uint256 minted, uint256 extra) public {
        _assumeEoa(to);
        minted = bound(minted, 1, 1e18);
        extra = bound(extra, 1, 1e18);

        vm.prank(minter);
        carbon.mintBatch(to, projectId, minted, VERIFICATION);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC1155Errors.ERC1155InsufficientBalance.selector, to, minted, minted + extra, projectId
            )
        );
        vm.prank(to);
        carbon.retire(projectId, minted + extra, "fuzz");
        assertEq(carbon.totalRetired(projectId), 0);
    }

    function testFuzz_TotalRetiredIsMonotonic(
        address to,
        uint256 projectId,
        uint256 firstMint,
        uint256 firstRetire,
        uint256 secondMint,
        uint256 secondRetire
    ) public {
        _assumeEoa(to);
        firstMint = bound(firstMint, 1, 1e18);
        firstRetire = bound(firstRetire, 1, firstMint);
        secondMint = bound(secondMint, 1, 1e18);
        secondRetire = bound(secondRetire, 1, firstMint - firstRetire + secondMint);

        vm.prank(minter);
        carbon.mintBatch(to, projectId, firstMint, VERIFICATION);
        vm.prank(to);
        carbon.retire(projectId, firstRetire, "one");
        uint256 afterFirst = carbon.totalRetired(projectId);

        vm.prank(minter);
        carbon.mintBatch(to, projectId, secondMint, VERIFICATION);
        assertEq(carbon.totalRetired(projectId), afterFirst);

        vm.prank(to);
        carbon.retire(projectId, secondRetire, "two");
        assertGe(carbon.totalRetired(projectId), afterFirst);
        assertEq(carbon.totalRetired(projectId), firstRetire + secondRetire);
    }

    function testFuzz_MintRejectsZeroAmount(address to, uint256 projectId, bytes32 hash) public {
        _assumeEoa(to);
        vm.expectRevert(CarbonCredit.InvalidAmount.selector);
        vm.prank(minter);
        carbon.mintBatch(to, projectId, 0, hash);
    }

    function testFuzz_UnauthorizedCannotMint(
        address caller,
        address to,
        uint256 projectId,
        uint256 amount,
        bytes32 hash
    ) public {
        _assumeEoa(to);
        vm.assume(caller != admin && caller != minter);
        amount = bound(amount, 1, 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, caller, carbon.MINTER_ROLE()
            )
        );
        vm.prank(caller);
        carbon.mintBatch(to, projectId, amount, hash);
    }

    function _assumeEoa(address to) internal view {
        vm.assume(to != address(0));
        vm.assume(to != address(carbon));
        vm.assume(to != address(registry));
        vm.assume(to.code.length == 0);
    }
}
