// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {CarbonCredit} from "../src/CarbonCredit.sol";
import {RetirementRegistry} from "../src/RetirementRegistry.sol";

/// @dev 共用部署：管理員鑄幣、授予 RECORDER_ROLE。
abstract contract BaseTest is Test {
    bytes32 internal constant VERIFICATION = keccak256("verification");
    string internal constant URI = "https://aegis.local/credits/{id}.json";

    CarbonCredit internal carbon;
    RetirementRegistry internal registry;

    address internal admin;
    address internal minter;
    address internal pauser;
    address internal holder;
    address internal stranger;

    function setUp() public virtual {
        admin = makeAddr("admin");
        minter = makeAddr("minter");
        pauser = makeAddr("pauser");
        holder = makeAddr("holder");
        stranger = makeAddr("stranger");

        vm.startPrank(admin);
        registry = new RetirementRegistry(admin);
        carbon = new CarbonCredit(admin, address(registry), URI);
        registry.grantRole(registry.RECORDER_ROLE(), address(carbon));
        carbon.grantRole(carbon.MINTER_ROLE(), minter);
        carbon.grantRole(carbon.PAUSER_ROLE(), pauser);
        vm.stopPrank();
    }

    function _mint(address to, uint256 projectId, uint256 amount) internal {
        vm.prank(minter);
        carbon.mintBatch(to, projectId, amount, VERIFICATION);
    }
}
