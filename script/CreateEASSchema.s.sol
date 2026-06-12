// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

struct SchemaRecord {
    bytes32 uid;
    address resolver;
    bool revocable;
    string schema;
}

/// @dev `register` / `getSchema` live on the SchemaRegistry, NOT on the EAS
///      contract. Calling them on EAS reverts and the schema is never created
///      (which is how schema 0xb72749f9... ended up unregistered and milestone
///      attestations reverted with InvalidSchema()).
interface ISchemaRegistry {
    function register(string calldata schema, address resolver, bool revocable) external returns (bytes32);
    function getSchema(bytes32 uid) external view returns (SchemaRecord memory);
}

interface IEAS {
    function getSchemaRegistry() external view returns (address);
}

/// @title CreateEASSchema
/// @notice Registers the warning schema for SentinelEAS on the EAS SchemaRegistry.
contract CreateEASSchema is Script {
    // Fields: grantId (bytes32), milestoneIndex (uint256), message (string)
    string constant SCHEMA = "bytes32 grantId,uint256 milestoneIndex,string message";
    address constant RESOLVER = address(0); // No resolver
    bool constant REVOCABLE = true;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address eas = vm.envAddress("EAS_ADDRESS");

        ISchemaRegistry registry = ISchemaRegistry(IEAS(eas).getSchemaRegistry());
        console.log("EAS Contract:   ", eas);
        console.log("SchemaRegistry: ", address(registry));
        console.log("Schema:         ", SCHEMA);

        // EAS schema UIDs are deterministic (keccak256(schema, resolver, revocable)),
        // so registering an existing schema reverts with AlreadyExists. Skip if present.
        bytes32 expectedUid = keccak256(abi.encodePacked(SCHEMA, RESOLVER, REVOCABLE));
        if (registry.getSchema(expectedUid).uid != bytes32(0)) {
            console.log("Schema already registered, skipping. UID:", vm.toString(expectedUid));
            return;
        }

        vm.startBroadcast(deployerKey);
        bytes32 schemaUid = registry.register(SCHEMA, RESOLVER, REVOCABLE);
        vm.stopBroadcast();

        console.log("Warning Schema UID:", vm.toString(schemaUid));
        console.log("\nUpdate SentinelEAS with this schema UID:");
        console.log("  SentinelEAS.setWarningSchema(", vm.toString(schemaUid), ")");
    }
}
