// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

interface IEAS {
    struct SchemaRecord {
        bytes32 uid;
        address resolver;
        bool revocable;
        string schema;
    }
    
    function register(string calldata schema, address resolver, bool revocable) external returns (bytes32);
    function getSchema(bytes32 uid) external view returns (SchemaRecord memory);
}

/// @title CreateEASSchema
/// @notice Creates the warning schema for SentinelEAS on Arbitrum Sepolia
contract CreateEASSchema is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address eas = vm.envAddress("EAS_ADDRESS");
        
        console.log("Creating EAS schema...");
        console.log("EAS Contract:", eas);
        
        vm.startBroadcast(deployerKey);
        
        // Schema for milestone warnings
        // Fields: grantId (bytes32), milestoneIndex (uint256), message (string)
        string memory schema = "bytes32 grantId,uint256 milestoneIndex,string message";
        
        IEAS easContract = IEAS(eas);
        bytes32 schemaUid = easContract.register(
            schema,
            address(0), // No resolver
            true        // Revocable
        );
        
        console.log("Warning Schema UID:", vm.toString(schemaUid));
        console.log("\nUpdate SentinelEAS with this schema UID:");
        console.log("  SentinelEAS.setWarningSchema(", vm.toString(schemaUid), ")");
        
        vm.stopBroadcast();
    }
}
