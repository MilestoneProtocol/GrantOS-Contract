// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/INoirVerifier.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IGrantIdentityRegistry {
    function isVerified(address wallet) external view returns (bool);
}

interface ISentinelEAS {
    function getWarningAge(bytes32 grantId, uint256 milestoneIndex) external view returns (uint256);
    function hasValidWarning(bytes32 grantId, uint256 milestoneIndex) external view returns (bool);
}

interface ISablierV2LockupLinear {
    struct CreateWithDurations {
        address sender;
        address recipient;
        uint128 totalAmount;
        address asset;
        bool cancelable;
        bool transferable;
        Durations durations;
        Broker broker;
    }
    struct Durations {
        uint40 cliff;
        uint40 total;
    }
    struct Broker {
        address account;
        uint256 fee;
    }
    function createWithDurations(CreateWithDurations calldata params) external returns (uint256 streamId);
    function cancel(uint256 streamId) external;
}

contract GrantEscrow {
    enum MilestoneState { Pending, Submitted, Approved, Rejected, Slashed, Streaming }

    // Proof type: 0 = ZK GitHub Proof required, 1 = EAS evidence only
    enum ProofType { ZKGitHub, EASOnly }

    struct Milestone {
        string title;
        string description;
        uint256 amount;
        uint256 deadline;
        ProofType proofType;
        MilestoneState state;
    }

    /// @notice On-chain record of a milestone submission for auditability.
    struct Submission {
        bytes32 proofHash;       // keccak256 of the ZK proof bytes (or 0x0 for EAS-only)
        bytes32 easAttestationUid; // EAS attestation UID (includes AI verdict + summary)
        string  builderSummary;  // Builder's written summary of what the PR delivers
        uint256 submittedAt;     // Block timestamp of submission
        uint256 approvalCount;   // Number of committee approvals received
        uint256 rejectionCount;  // Number of committee rejections received
    }

    IERC20 public usdc;
    IGrantIdentityRegistry public registry;
    ISentinelEAS public sentinel;
    ISablierV2LockupLinear public sablier;
    INoirVerifier public verifier;

    address public grantor;
    address public grantee;
    address[] public committee;
    uint256 public quorum;
    bool public isStreaming;
    bool public cancelled;
    uint256 public createdAt;
    bytes32 public grantId;

    Milestone[] public milestones;
    mapping(uint256 => Submission) public submissions;
    mapping(uint256 => uint256) public milestoneStreams;

    /// @notice Tracks committee votes: milestoneId => voter => true if voted
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    bool private _locked;

    // ── Events ──────────────────────────────────────────────────────────────

    event MilestoneSubmitted(
        uint256 indexed milestoneId,
        address indexed builder,
        bytes32 proofHash,
        bytes32 easAttestationUid,
        string  builderSummary
    );

    event VoteCast(
        uint256 indexed milestoneId,
        address indexed voter,
        bool    approved,
        uint256 approvalCount,
        uint256 rejectionCount
    );

    event MilestoneApproved(
        uint256 indexed milestoneId,
        uint256 amount,
        bool    streaming
    );

    event MilestoneRejected(
        uint256 indexed milestoneId,
        uint256 rejectionCount
    );

    event GrantCancelled(address indexed grantor, uint256 refundedAmount);

    // ── Modifiers ───────────────────────────────────────────────────────────

    modifier nonReentrant() {
        require(!_locked, "ReentrancyGuard: reentrant call");
        _locked = true;
        _;
        _locked = false;
    }

    modifier onlyGrantor() {
        require(msg.sender == grantor, "Only grantor");
        _;
    }

    modifier onlyGrantee() {
        require(msg.sender == grantee, "Only grantee");
        _;
    }

    modifier onlyCommittee() {
        bool isMember = false;
        for (uint i = 0; i < committee.length; i++) {
            if (committee[i] == msg.sender) {
                isMember = true;
                break;
            }
        }
        require(isMember, "Only committee member");
        _;
    }

    modifier notCancelled() {
        require(!cancelled, "Grant is cancelled");
        _;
    }

    struct MilestoneInput {
        string title;
        string description;
        uint256 amount;
        uint256 deadline;
        ProofType proofType;
    }

    // ── Initialisation (called by GrantFactory after clone) ─────────────────

    function initialize(
        address _usdc,
        address _registry,
        address _sentinel,
        address _sablier,
        address _grantor,
        address _grantee,
        bool _isStreaming,
        address[] calldata _committee,
        uint256 _quorum,
        MilestoneInput[] calldata _milestones,
        bytes32 _grantId
    ) external {
        require(grantor == address(0), "Already initialized");
        require(_committee.length >= 2 && _committee.length <= 7, "Committee: 2-7 members");
        require(_quorum >= 1 && _quorum <= _committee.length, "Invalid quorum");
        require(_milestones.length >= 1 && _milestones.length <= 10, "Milestones: 1-10");

        usdc = IERC20(_usdc);
        registry = IGrantIdentityRegistry(_registry);
        sentinel = ISentinelEAS(_sentinel);
        sablier = ISablierV2LockupLinear(_sablier);
        grantor = _grantor;
        grantee = _grantee;
        isStreaming = _isStreaming;
        committee = _committee;
        quorum = _quorum;
        createdAt = block.timestamp;
        grantId = _grantId;

        for (uint i = 0; i < _milestones.length; i++) {
            milestones.push(Milestone({
                title: _milestones[i].title,
                description: _milestones[i].description,
                amount: _milestones[i].amount,
                deadline: _milestones[i].deadline,
                proofType: _milestones[i].proofType,
                state: MilestoneState.Pending
            }));
        }
    }

    /// @notice Set the Noir verifier contract. Called once by the factory during creation.
    function setVerifier(address _verifier) external {
        require(address(verifier) == address(0), "Verifier already set");
        // We allow the factory to set this during the initialization transaction
        verifier = INoirVerifier(_verifier);
    }

    // ── View helpers ────────────────────────────────────────────────────────

    function getMilestoneCount() external view returns (uint256) {
        return milestones.length;
    }

    function getMilestoneStatus(uint256 milestoneIndex) external view returns (MilestoneState) {
        return milestones[milestoneIndex].state;
    }

    function getSubmission(uint256 milestoneId) external view returns (Submission memory) {
        return submissions[milestoneId];
    }

    function getCommittee() external view returns (address[] memory) {
        return committee;
    }

    function getCommitteeLength() external view returns (uint256) {
        return committee.length;
    }

    struct GrantView {
        address builder;
        bool streaming;
        address[] committee;
        uint256 quorum;
        uint256 createdAt;
        Milestone[] milestones;
    }

    function getGrant() external view returns (GrantView memory) {
        return GrantView({
            builder: grantee,
            streaming: isStreaming,
            committee: committee,
            quorum: quorum,
            createdAt: createdAt,
            milestones: milestones
        });
    }

    /// @notice Get streaming info for active streaming milestones
    function getStreamingInfo() external view returns (
        uint256 activeStreamCount,
        uint256 totalStreamingAmount,
        int96 totalFlowRate
    ) {
        for (uint i = 0; i < milestones.length; i++) {
            if (milestones[i].state == MilestoneState.Streaming) {
                activeStreamCount++;
                totalStreamingAmount += milestones[i].amount;
                // With Sablier, we stream the total amount over 30 days
                totalFlowRate += int96(int256(milestones[i].amount / 30 days));
            }
        }
    }

    // ── Milestone Submission (US-02) ────────────────────────────────────────

    /**
     * @notice Submit a milestone with cryptographic proof.
     * @param milestoneId      Index of the milestone to submit
     * @param proof            ZK proof bytes (empty for EAS-only milestones)
     * @param publicInputs     ZK public inputs (empty for EAS-only milestones)
     * @param easAttestationUid EAS attestation UID containing AI verdict + summary
     * @param builderSummary   Builder's written explanation of what the PR delivers
     *
     * For ZK-required milestones:
     *   1. Builder must be ZK-verified in the IdentityRegistry
     *   2. The proof is verified on-chain via the WebProofVerifier
     *   3. If verification fails, the transaction reverts
     *
     * For EAS-only milestones:
     *   - No ZK proof verification, but EAS attestation is still recorded
     */
    function submitMilestone(
        uint256 milestoneId,
        bytes calldata proof,
        bytes32[] calldata publicInputs,
        bytes32 easAttestationUid,
        string calldata builderSummary
    ) external onlyGrantee notCancelled {
        require(milestoneId < milestones.length, "Invalid milestone");
        Milestone storage m = milestones[milestoneId];
        require(
            m.state == MilestoneState.Pending || m.state == MilestoneState.Rejected,
            "Invalid state for submission"
        );

        bytes32 proofHash;

        if (m.proofType == ProofType.ZKGitHub) {
            // Must be ZK-verified in IdentityRegistry
            require(registry.isVerified(msg.sender), "ZK Identity required");

            // Proof must be non-empty for ZK milestones
            require(proof.length > 0, "ZK proof required");

            // Verify proof on-chain — reverts if invalid
            if (address(verifier) != address(0)) {
                // publicInputs format from main.nr:
                // [3] wallet_address_hi (upper 4 bytes)
                // [4] wallet_address_lo (lower 16 bytes)
                require(publicInputs.length >= 5, "Missing public inputs");

                uint160 addressHi = uint160(uint256(publicInputs[3])) << 128;
                uint160 addressLo = uint160(uint256(publicInputs[4]));
                require((addressHi | addressLo) == uint160(grantee), "Proof not bound to grantee");

                require(
                    verifier.verify(proof, publicInputs),
                    "ZK proof verification failed"
                );
            }

            proofHash = keccak256(proof);
        }

        // Reset any previous votes (for resubmission after rejection)
        _resetVotes(milestoneId);

        // Record submission
        submissions[milestoneId] = Submission({
            proofHash: proofHash,
            easAttestationUid: easAttestationUid,
            builderSummary: builderSummary,
            submittedAt: block.timestamp,
            approvalCount: 0,
            rejectionCount: 0
        });

        m.state = MilestoneState.Submitted;

        emit MilestoneSubmitted(
            milestoneId,
            msg.sender,
            proofHash,
            easAttestationUid,
            builderSummary
        );
    }

    // ── Committee Voting (US-03) ────────────────────────────────────────────

    /**
     * @notice Cast an approval vote on a submitted milestone.
     * @param milestoneId Index of the milestone to approve
     *
     * When the approval count reaches quorum:
     *   - Streaming mode: Superfluid flow begins
     *   - Lump-sum mode: USDC transfers immediately
     */
    function approveMilestone(uint256 milestoneId) external onlyCommittee notCancelled nonReentrant {
        require(milestoneId < milestones.length, "Invalid milestone");
        Milestone storage m = milestones[milestoneId];
        require(m.state == MilestoneState.Submitted, "Not submitted");
        require(!hasVoted[milestoneId][msg.sender], "Already voted");

        hasVoted[milestoneId][msg.sender] = true;
        submissions[milestoneId].approvalCount += 1;

        uint256 approvalCount = submissions[milestoneId].approvalCount;
        uint256 rejectionCount = submissions[milestoneId].rejectionCount;

        emit VoteCast(milestoneId, msg.sender, true, approvalCount, rejectionCount);

        // Check if quorum reached
        if (approvalCount >= quorum) {
            if (isStreaming) {
                m.state = MilestoneState.Streaming;
                
                // Stream the payout over a fixed 30 days instead of tying it to the submission deadline
                uint40 duration = 30 days;
                
                // Approve Sablier to spend the USDC
                usdc.approve(address(sablier), m.amount);
                
                ISablierV2LockupLinear.CreateWithDurations memory params = ISablierV2LockupLinear.CreateWithDurations({
                    sender: address(this),
                    recipient: grantee,
                    totalAmount: uint128(m.amount),
                    asset: address(usdc),
                    cancelable: true,
                    transferable: false,
                    durations: ISablierV2LockupLinear.Durations({
                        cliff: 0,
                        total: duration
                    }),
                    broker: ISablierV2LockupLinear.Broker({
                        account: address(0),
                        fee: 0
                    })
                });
                
                uint256 streamId = sablier.createWithDurations(params);
                milestoneStreams[milestoneId] = streamId;
            } else {
                m.state = MilestoneState.Approved;
                require(usdc.transfer(grantee, m.amount), "Transfer failed");
            }
            emit MilestoneApproved(milestoneId, m.amount, isStreaming);
        }
    }

    /**
     * @notice Cast a rejection vote on a submitted milestone.
     * @param milestoneId Index of the milestone to reject
     *
     * When rejections reach (committee.length - quorum + 1), the milestone
     * returns to Pending so the builder can resubmit with a new ZK proof.
     */
    function rejectMilestone(uint256 milestoneId) external onlyCommittee notCancelled {
        require(milestoneId < milestones.length, "Invalid milestone");
        Milestone storage m = milestones[milestoneId];
        require(m.state == MilestoneState.Submitted, "Not submitted");
        require(!hasVoted[milestoneId][msg.sender], "Already voted");

        hasVoted[milestoneId][msg.sender] = true;
        submissions[milestoneId].rejectionCount += 1;

        uint256 approvalCount = submissions[milestoneId].approvalCount;
        uint256 rejectionCount = submissions[milestoneId].rejectionCount;

        emit VoteCast(milestoneId, msg.sender, false, approvalCount, rejectionCount);

        // If enough rejections to make quorum impossible, auto-reject
        uint256 rejectThreshold = committee.length - quorum + 1;
        if (rejectionCount >= rejectThreshold) {
            m.state = MilestoneState.Pending; // Return to Pending for resubmission
            _resetVotes(milestoneId);
            emit MilestoneRejected(milestoneId, rejectionCount);
        }
    }

    // ── Slashing ────────────────────────────────────────────────────────────

    event MilestoneSlashed(
        uint256 indexed milestoneId,
        address indexed grantor,
        uint256 amount,
        uint256 slashedAt
    );

    function slashMilestone(uint256 milestoneId) external onlyCommittee notCancelled nonReentrant {
        require(milestoneId < milestones.length, "Invalid milestone");
        Milestone storage m = milestones[milestoneId];
        require(m.state == MilestoneState.Pending || m.state == MilestoneState.Submitted, "Invalid state for slash");
        require(m.state != MilestoneState.Slashed, "Already slashed");
        require(block.timestamp > m.deadline, "Milestone not overdue");

        // Verify warning exists and is older than 24 hours
        require(sentinel.hasValidWarning(grantId, milestoneId), "Valid warning required (24h+ old)");

        if (m.state == MilestoneState.Streaming) {
            sablier.cancel(milestoneStreams[milestoneId]);
        }

        m.state = MilestoneState.Slashed;
        // Transfer remaining balance of this milestone to grantor
        // For lump-sum, this is m.amount. For streaming, it's whatever was refunded to us by Sablier
        uint256 refundAmount = m.state == MilestoneState.Streaming ? usdc.balanceOf(address(this)) : m.amount;
        if (refundAmount > 0) {
            require(usdc.transfer(grantor, refundAmount), "Transfer failed");
        }

        emit MilestoneSlashed(milestoneId, grantor, m.amount, block.timestamp);
    }

    // ── Grant Cancellation ──────────────────────────────────────────────────

    /**
     * @notice Cancel the grant and reclaim all remaining (unspent) USDC.
     * Milestones that are already Approved or Slashed are skipped.
     * All other milestones are marked Slashed and their funds are returned
     * to the grantor.
     */
    function cancelGrant() external onlyGrantor notCancelled nonReentrant {
        cancelled = true;

        uint256 refund = 0;
        for (uint i = 0; i < milestones.length; i++) {
            Milestone storage m = milestones[i];
            // Skip milestones whose funds have already left the escrow
            if (m.state == MilestoneState.Approved || m.state == MilestoneState.Slashed) {
                continue;
            }
            // Stop any active streams
            if (m.state == MilestoneState.Streaming) {
                sablier.cancel(milestoneStreams[i]);
                // Sablier refunds unstreamed tokens back to the sender (this escrow contract)
            } else {
                refund += m.amount;
            }
            m.state = MilestoneState.Slashed;
        }

        // Add any tokens refunded by Sablier
        refund += usdc.balanceOf(address(this));

        if (refund > 0) {
            require(usdc.transfer(grantor, refund), "Refund transfer failed");
        }

        emit GrantCancelled(grantor, refund);
    }

    // ── Internal helpers ────────────────────────────────────────────────────

    /**
     * @dev Reset all committee votes for a milestone (used on rejection/resubmission)
     */
    function _resetVotes(uint256 milestoneId) internal {
        for (uint i = 0; i < committee.length; i++) {
            hasVoted[milestoneId][committee[i]] = false;
        }
    }
}
