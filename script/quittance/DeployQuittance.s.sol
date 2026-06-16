// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Quittance} from "../../src/quittance/Quittance.sol";

/**
 * @notice Deploys Quittance to the configured network.
 *
 * Usage:
 *   forge script script/quittance/DeployQuittance.s.sol \
 *     --rpc-url $RPC --private-key $PRIVATE_KEY --broadcast
 */
contract DeployQuittance is Script {
    function run() external returns (Quittance rail) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);
        rail = new Quittance();
        vm.stopBroadcast();
        console.log("Quittance deployed at:", address(rail));
        console.log("DOMAIN_SEPARATOR:");
        console.logBytes32(rail.DOMAIN_SEPARATOR());
    }
}
