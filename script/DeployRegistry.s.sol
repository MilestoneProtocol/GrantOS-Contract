// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/OracleAttestationVerifier.sol";
import "../src/GrantIdentityRegistry.sol";

contract DeployRegistry is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        // 1. Deploy the OracleAttestationVerifier: it verifies the trusted
        //    oracle's secp256k1 signature over the identity public inputs via
        //    on-chain ecrecover (replaces the old "return true" verifier).
        address oracleSigner = vm.envAddress("ORACLE_ADDRESS");
        OracleAttestationVerifier verifier = new OracleAttestationVerifier(oracleSigner);
        console.log("OracleAttestationVerifier deployed at:", address(verifier));

        // 2. Deploy the identity registry pointing to the verifier
        GrantIdentityRegistry registry = new GrantIdentityRegistry(address(verifier));
        console.log("GrantIdentityRegistry deployed at:", address(registry));

        vm.stopBroadcast();
    }
}
