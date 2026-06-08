// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/UltraHonkVerifier.sol";
import "../src/GrantIdentityRegistry.sol";

contract DeployRegistry is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        // 1. Deploy the production verifier (input + wallet-binding validation
        //    on-chain; full ZK verification is performed off-chain by the
        //    backend with Barretenberg — never the "return true" StubNoirVerifier).
        UltraHonkVerifier verifier = new UltraHonkVerifier();
        console.log("UltraHonkVerifier deployed at:", address(verifier));

        // 2. Deploy the identity registry pointing to the verifier
        GrantIdentityRegistry registry = new GrantIdentityRegistry(address(verifier));
        console.log("GrantIdentityRegistry deployed at:", address(registry));

        vm.stopBroadcast();
    }
}
