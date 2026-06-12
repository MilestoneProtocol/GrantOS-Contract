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
    uint256 public constant WARNING_MATURITY = 24 hours;
    uint256 public constant WARNING_EXPIRY = 7 days;

    IEAS public eas;
    bytes32 public warningSchema;

    /// @notice Protocol admin able to manage the authorized-issuer set.
    address public owner;
    /// @notice Addresses permitted to issue warnings (e.g. the sentinel keeper
    ///         or grant committee operators). Without this gate any account
    ///         could plant or reset warnings and manipulate the slashing path.
    mapping(address => bool) public authorizedIssuers;

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
    event WarningDeactivated(bytes32 indexed grantId, uint256 indexed milestoneIndex, address indexed by);
    event AuthorizedIssuerSet(address indexed issuer, bool allowed);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(address _eas, bytes32 _warningSchema) {
        eas = IEAS(_eas);
        warningSchema = _warningSchema;
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    /// @notice Grant or revoke an address's ability to issue warnings.
    function setAuthorizedIssuer(address issuer, bool allowed) external onlyOwner {
        authorizedIssuers[issuer] = allowed;
        emit AuthorizedIssuerSet(issuer, allowed);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function issueWarning(bytes32 grantId, uint256 milestoneIndex, address recipient, string calldata message)
        external
        returns (bytes32)
    {
        require(authorizedIssuers[msg.sender], "Not authorized issuer");

        // Anti-reset guard: do not overwrite a warning that is still active and
        // within its valid lifetime. Otherwise a fresh issuance would reset the
        // timestamp and push a maturing warning back below WARNING_MATURITY,
        // indefinitely blocking slashing. Re-issuing is allowed once the prior
        // warning has been deactivated or has expired.
        MilestoneWarning storage existing = warnings[grantId][milestoneIndex];
        require(!existing.active || block.timestamp - existing.timestamp >= WARNING_EXPIRY, "Active warning exists");

        // Encode warning data: grantId, milestoneIndex, message
        bytes memory data = abi.encode(grantId, milestoneIndex, message);

        IEAS.AttestationRequest memory request = IEAS.AttestationRequest({
            schema: warningSchema,
            data: IEAS.AttestationRequestData({
                recipient: recipient, expirationTime: 0, revocable: true, refUID: bytes32(0), data: data, value: 0
            })
        });

        bytes32 uid = eas.attest(request);

        warnings[grantId][milestoneIndex] = MilestoneWarning({
            attestationUid: uid, timestamp: uint64(block.timestamp), issuer: msg.sender, active: true
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
        return age >= WARNING_MATURITY && age < WARNING_EXPIRY;
    }

    /// @notice Deactivate a warning. Restricted to the original issuer or the
    ///         owner so a grantee cannot neutralize the warning that gates
    ///         slashing of their overdue milestone.
    function deactivateWarning(bytes32 grantId, uint256 milestoneIndex) external {
        MilestoneWarning storage warning = warnings[grantId][milestoneIndex];
        require(msg.sender == warning.issuer || msg.sender == owner, "Not authorized");
        warning.active = false;
        emit WarningDeactivated(grantId, milestoneIndex, msg.sender);
    }
}
