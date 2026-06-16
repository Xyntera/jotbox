// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PayRail} from "../../src/payrail/PayRail.sol";

/**
 * @notice Deploys PayRail to the configured network.
 *
 * Usage:
 *   forge script script/payrail/DeployPayRail.s.sol \
 *     --rpc-url $RPC --private-key $PRIVATE_KEY --broadcast
 */
contract DeployPayRail is Script {
    function run() external returns (PayRail rail) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);
        rail = new PayRail();
        vm.stopBroadcast();
        console.log("PayRail deployed at:", address(rail));
        console.log("DOMAIN_SEPARATOR:");
        console.logBytes32(rail.DOMAIN_SEPARATOR());
    }
}
