// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Minimal interface for EAS (Ethereum Attestation Service)
interface IEAS {
    struct AttestationRequestData {
        address recipient;
        uint64 expirationTime;
        bool revocable;
        bytes32 refUID;
        bytes data;
        uint256 value;
    }

    struct AttestationRequest {
        bytes32 schema;
        AttestationRequestData data;
    }

    struct Attestation {
        bytes32 uid;
        bytes32 schema;
        uint64 time;
        uint64 expirationTime;
        uint64 revocationTime;
        bytes32 refUID;
        address recipient;
        address attester;
        bool revocable;
        bytes data;
    }

    function attest(AttestationRequest calldata request) external payable returns (bytes32);
    function getAttestation(bytes32 uid) external view returns (Attestation memory);
}

contract SentinelEAS {
    IEAS public eas;
    bytes32 public warningSchema;

    struct MilestoneWarning {
        bytes32 attestationUid;
        uint64 timestamp;
        address issuer;
        bool active;
    }

    // grantId => milestoneIndex => warning
    mapping(bytes32 => mapping(uint256 => MilestoneWarning)) public warnings;
    
    event WarningIssued(
        bytes32 indexed grantId,
        uint256 indexed milestoneIndex,
        address indexed recipient,
        bytes32 attestationUid,
        string message
    );

    constructor(address _eas, bytes32 _warningSchema) {
        eas = IEAS(_eas);
        warningSchema = _warningSchema;
    }

    function issueWarning(
        bytes32 grantId,
        uint256 milestoneIndex,
        address recipient,
        string calldata message
    ) external returns (bytes32) {
        // Encode warning data: grantId, milestoneIndex, message
        bytes memory data = abi.encode(grantId, milestoneIndex, message);
        
        IEAS.AttestationRequest memory request = IEAS.AttestationRequest({
            schema: warningSchema,
            data: IEAS.AttestationRequestData({
                recipient: recipient,
                expirationTime: 0,
                revocable: true,
                refUID: bytes32(0),
                data: data,
                value: 0
            })
        });

        bytes32 uid = eas.attest(request);
        
        warnings[grantId][milestoneIndex] = MilestoneWarning({
            attestationUid: uid,
            timestamp: uint64(block.timestamp),
            issuer: msg.sender,
            active: true
        });
        
        emit WarningIssued(grantId, milestoneIndex, recipient, uid, message);
        return uid;
    }

    function getWarningAge(bytes32 grantId, uint256 milestoneIndex) external view returns (uint256) {
        MilestoneWarning memory warning = warnings[grantId][milestoneIndex];
        if (!warning.active || warning.timestamp == 0) return 0;
        return block.timestamp - warning.timestamp;
    }

    function hasValidWarning(bytes32 grantId, uint256 milestoneIndex) external view returns (bool) {
        MilestoneWarning memory warning = warnings[grantId][milestoneIndex];
        if (!warning.active || warning.timestamp == 0) return false;
        
        uint256 age = block.timestamp - warning.timestamp;
        return age >= 24 hours && age < 7 days;
    }

    function deactivateWarning(bytes32 grantId, uint256 milestoneIndex) external {
        warnings[grantId][milestoneIndex].active = false;
    }
}
