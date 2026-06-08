// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/UltraHonkVerifier.sol";
import "../src/GrantIdentityRegistry.sol";
import "../src/GrantEscrow.sol";
import "../src/GrantFactory.sol";
import "../src/SentinelEAS.sol";

/// @title DeployAll
/// @notice Deploys the complete GrantOS v3 system with production UltraHonkVerifier
contract DeployAll is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        
        console.log("Deploying from:", deployer);
        console.log("Chain ID:", block.chainid);
        
        vm.startBroadcast(deployerKey);

        // 1. Deploy UltraHonkVerifier (production verifier with off-chain verification)
        UltraHonkVerifier verifier = new UltraHonkVerifier();
        console.log("UltraHonkVerifier deployed at:", address(verifier));

        // 2. Deploy GrantIdentityRegistry
        GrantIdentityRegistry registry = new GrantIdentityRegistry(address(verifier));
        console.log("GrantIdentityRegistry deployed at:", address(registry));

        // 3. Get external contract addresses from environment
        address usdc = vm.envAddress("USDC_ADDRESS");
        address eas = vm.envAddress("EAS_ADDRESS");
        address sablier = vm.envAddress("SABLIER_ADDRESS");
        
        console.log("Using USDC at:", usdc);
        console.log("Using EAS at:", eas);
        console.log("Using Sablier at:", sablier);

        // 4. Deploy SentinelEAS (with empty schema for now, can be set later)
        bytes32 warningSchema = bytes32(0);
        SentinelEAS sentinel = new SentinelEAS(eas, warningSchema);
        console.log("SentinelEAS deployed at:", address(sentinel));

        // 5. Deploy GrantEscrow implementation (used as EIP-1167 clone template)
        GrantEscrow escrowImpl = new GrantEscrow();
        console.log("GrantEscrow implementation deployed at:", address(escrowImpl));

        // 6. Deploy GrantFactory with implementation address
        GrantFactory factory = new GrantFactory(
            address(escrowImpl),
            usdc,
            address(registry),
            address(sentinel),
            sablier,
            address(verifier)
        );
        console.log("GrantFactory deployed at:", address(factory));

        vm.stopBroadcast();

        // Print deployment summary
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("Network:", block.chainid);
        console.log("Deployer:", deployer);
        console.log("\nCore Contracts:");
        console.log("  UltraHonkVerifier:", address(verifier));
        console.log("  GrantIdentityRegistry:", address(registry));
        console.log("  SentinelEAS:", address(sentinel));
        console.log("  GrantEscrow (impl):", address(escrowImpl));
        console.log("  GrantFactory:", address(factory));
        console.log("\nExternal Dependencies:");
        console.log("  USDC:", usdc);
        console.log("  EAS:", eas);
        console.log("  Sablier:", sablier);
        console.log("\n=== UPDATE FRONTEND ENV ===");
        console.log("NEXT_PUBLIC_GRANT_FACTORY_ADDRESS=", address(factory));
        console.log("NEXT_PUBLIC_IDENTITY_REGISTRY_ADDRESS=", address(registry));
        console.log("NEXT_PUBLIC_VERIFIER_ADDRESS=", address(verifier));
    }
}
