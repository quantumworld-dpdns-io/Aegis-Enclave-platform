// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {CarbonCredit} from "../../src/CarbonCredit.sol";
import {RetirementRegistry} from "../../src/RetirementRegistry.sol";

/// @dev Invariant handler：所有輸入都 bound 在合法區間，配合 `fail_on_revert = true`。
contract RetirementHandler is Test {
    uint256 public constant MAX_PROJECTS = 8;
    uint256 public constant ACTOR_COUNT = 5;
    uint256 public constant MAX_MINT = 1_000_000_000;

    CarbonCredit public immutable carbon;
    RetirementRegistry public immutable registry;
    address public immutable minter;

    address[] public actors;

    mapping(uint256 projectId => uint256) public ghostMinted;
    mapping(uint256 projectId => uint256) public ghostBurned;
    mapping(uint256 projectId => uint256) public ghostRetired;
    mapping(uint256 projectId => uint256) public lastSeenRetired;

    constructor(CarbonCredit carbon_, RetirementRegistry registry_, address minter_) {
        carbon = carbon_;
        registry = registry_;
        minter = minter_;
        for (uint256 i = 0; i < ACTOR_COUNT; ++i) {
            actors.push(makeAddr(string.concat("actor-", vm.toString(i))));
        }
    }

    function mint(uint256 actorSeed, uint256 projectSeed, uint256 amount, bytes32 verificationHash) external {
        address to = _actor(actorSeed);
        uint256 projectId = bound(projectSeed, 0, MAX_PROJECTS - 1);
        amount = bound(amount, 1, MAX_MINT);

        vm.prank(minter);
        carbon.mintBatch(to, projectId, amount, verificationHash);

        ghostMinted[projectId] += amount;
        _snapshot(projectId);
    }

    function retire(uint256 actorSeed, uint256 projectSeed, uint256 amount) external {
        address by = _actor(actorSeed);
        uint256 projectId = bound(projectSeed, 0, MAX_PROJECTS - 1);
        uint256 bal = carbon.balanceOf(by, projectId);
        if (bal == 0) {
            _snapshot(projectId);
            return;
        }
        amount = bound(amount, 1, bal);

        vm.prank(by);
        carbon.retire(projectId, amount, "beneficiary");

        ghostBurned[projectId] += amount;
        ghostRetired[projectId] += amount;
        _snapshot(projectId);
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 projectSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 projectId = bound(projectSeed, 0, MAX_PROJECTS - 1);
        if (from == to) {
            _snapshot(projectId);
            return;
        }
        uint256 bal = carbon.balanceOf(from, projectId);
        if (bal == 0) {
            _snapshot(projectId);
            return;
        }
        amount = bound(amount, 1, bal);

        vm.prank(from);
        carbon.safeTransferFrom(from, to, projectId, amount, "");
        _snapshot(projectId);
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, ACTOR_COUNT - 1)];
    }

    function _snapshot(uint256 projectId) internal {
        lastSeenRetired[projectId] = carbon.totalRetired(projectId);
    }
}
