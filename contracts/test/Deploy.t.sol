// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import {Test} from "forge-std/Test.sol";

import {Deploy} from "../script/Deploy.s.sol";
import {CarbonCredit} from "../src/CarbonCredit.sol";
import {RetirementRegistry} from "../src/RetirementRegistry.sol";

contract DeployTest is Test {
    using stdJson for string;

    function test_DeployWritesLocalJsonAndWiresRoles() public {
        Deploy deploy = new Deploy();
        (CarbonCredit carbon, RetirementRegistry registry) = deploy.run();

        string memory json = vm.readFile("./deployments/local.json");
        assertEq(json.readUint(".chainId"), block.chainid);
        assertEq(json.readAddress(".CarbonCredit"), address(carbon));
        assertEq(json.readAddress(".RetirementRegistry"), address(registry));

        assertEq(address(carbon.registry()), address(registry));
        assertTrue(registry.hasRole(registry.RECORDER_ROLE(), address(carbon)));
        assertTrue(carbon.hasRole(carbon.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(carbon.hasRole(carbon.MINTER_ROLE(), address(this)));

        address holder = makeAddr("deploy-holder");
        carbon.mintBatch(holder, 1, 5, keccak256("deploy"));
        vm.prank(holder);
        carbon.retire(1, 5, "deploy-test");
        assertEq(carbon.totalRetired(1), 5);
        assertEq(registry.totalRetired(1), 5);
    }
}
