// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/GrantEscrow.sol";
import "../src/GrantFactory.sol";

contract DeployCorrectFactory is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console.log("Deploying from:", deployer);
        console.log("Chain ID:", block.chainid);

        address usdc     = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d;
        address registry = 0xfEd8bf87F04a208a876252347FDB2dD1465322A5;
        address sentinel = 0x61c1b08f35DB847cE2Dc8ACa96063806fBa264b6;
        address sablier  = 0xd4300c5bC0B9e27c73eBAbDc747ba990B1B570Db;
        address verifier = 0x8F0087B6FA4eDB246F80ae8Dc71D163B10dc4878;

        vm.startBroadcast(deployerKey);

        // 1. Deploy the implementation escrow
        GrantEscrow implementation = new GrantEscrow();
        console.log("Deployed GrantEscrow implementation at:", address(implementation));

        // 2. Deploy the factory with correct constructor parameters
        GrantFactory factory = new GrantFactory(
            address(implementation),
            usdc,
            registry,
            sentinel,
            sablier,
            verifier
        );
        console.log("Deployed GrantFactory at:", address(factory));

        vm.stopBroadcast();
    }
}
