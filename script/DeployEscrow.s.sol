// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/GrantEscrow.sol";
import "../src/GrantFactory.sol";
import "../src/OracleAttestationVerifier.sol";

/**
 * Deploy GrantEscrow (implementation) + OracleAttestationVerifier + GrantFactory on Arbitrum Sepolia.
 *
 * Required env vars:
 *   DEPLOYER_PRIVATE_KEY          — deployer wallet key
 *   ORACLE_ADDRESS                — trusted oracle signer address for the verifier
 *   USDC_ADDRESS                  — USDC token on target chain
 *   IDENTITY_REGISTRY_ADDRESS     — deployed GrantIdentityRegistry
 *   SENTINEL_EAS_ADDRESS          — deployed SentinelEAS (or zero address for stub)
 *   SABLIER_ADDRESS               — Sablier V2 Lockup Linear contract
 *
 * Run:
 *   forge script script/DeployEscrow.s.sol --rpc-url $ARBITRUM_SEPOLIA_RPC \
 *     --broadcast --verify -vvvv
 */
contract DeployEscrow is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address registry = vm.envAddress("IDENTITY_REGISTRY_ADDRESS");
        address sentinel = vm.envOr("SENTINEL_EAS_ADDRESS", address(0));
        address sablier = vm.envOr("SABLIER_ADDRESS", address(0x483bdd560dE53DC20f72dC66ACdB622C5075de34));

        vm.startBroadcast(deployerKey);

        // 1. Deploy the implementation (never called directly — only cloned)
        GrantEscrow implementation = new GrantEscrow();
        console.log("GrantEscrow implementation:", address(implementation));

        // 2. Deploy the OracleAttestationVerifier (real on-chain ecrecover check
        //    of the trusted oracle's signature over the public inputs).
        address oracleSigner = vm.envAddress("ORACLE_ADDRESS");
        OracleAttestationVerifier verifier = new OracleAttestationVerifier(oracleSigner);
        console.log("OracleAttestationVerifier:", address(verifier));

        // 3. Deploy the factory pointing at the implementation + verifier
        GrantFactory factory =
            new GrantFactory(address(implementation), usdc, registry, sentinel, sablier, address(verifier));
        console.log("GrantFactory:", address(factory));

        vm.stopBroadcast();
    }
}
