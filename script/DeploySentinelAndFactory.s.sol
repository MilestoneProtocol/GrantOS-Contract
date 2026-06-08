// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/GrantFactory.sol";
import "../src/SentinelEAS.sol";

/// @notice Redeploys SentinelEAS with the real warning schema UID, then redeploys GrantFactory.
contract DeploySentinelAndFactory is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Existing deployed contracts (keep these)
        address usdc    = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d;
        address eas     = 0x2521021fc8BF070473E1e1801D3c7B4aB701E1dE;
        address sablier = 0xd4300c5bC0B9e27c73eBAbDc747ba990B1B570Db;
        address registry = 0x2514f05A498cb3452abeC1a3f8d5A07412A6C4Ad;
        address verifier = 0x082029B163e9bBff7Bc4aeA46710041eDd8bb1a4;

        bytes32 warningSchema = 0xb72749f9f346f14a19d3f9738d3c72972c5e185918656612ec2a299f2cc1fa29;

        vm.startBroadcast(deployerKey);

        SentinelEAS sentinel = new SentinelEAS(eas, warningSchema);
        console.log("SentinelEAS deployed at:", address(sentinel));

        GrantFactory factory = new GrantFactory(
            usdc,
            registry,
            address(sentinel),
            sablier,
            verifier,
            eas
        );
        console.log("GrantFactory deployed at:", address(factory));

        vm.stopBroadcast();

        console.log("\n=== UPDATE FRONTEND ENV ===");
        console.log("NEXT_PUBLIC_GRANT_FACTORY_ADDRESS=", address(factory));
    }
}
