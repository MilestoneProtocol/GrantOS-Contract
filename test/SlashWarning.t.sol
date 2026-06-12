// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/GrantEscrow.sol";
import "../src/SentinelEAS.sol";

contract MockEAS {
    uint64 private _time;

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

    mapping(bytes32 => Attestation) public attestations;

    function attest(IEAS.AttestationRequest calldata request) external returns (bytes32) {
        bytes32 uid = keccak256(abi.encodePacked(block.timestamp, msg.sender, request.data.recipient));
        attestations[uid] = Attestation({
            uid: uid,
            schema: request.schema,
            time: uint64(block.timestamp),
            expirationTime: request.data.expirationTime,
            revocationTime: 0,
            refUID: request.data.refUID,
            recipient: request.data.recipient,
            attester: msg.sender,
            revocable: request.data.revocable,
            data: request.data.data
        });
        return uid;
    }

    function getAttestation(bytes32 uid) external view returns (Attestation memory) {
        return attestations[uid];
    }
}

contract MockUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        return true;
    }
}

contract SlashWarningTest is Test {
    SentinelEAS public sentinel;
    MockEAS public eas;
    MockUSDC public usdc;
    GrantEscrow public escrow;

    address public grantor = address(0x1);
    address public grantee = address(0x2);
    address public committee1 = address(0x3);
    address public committee2 = address(0x4);

    bytes32 public grantId = bytes32(uint256(1));
    bytes32 public warningSchema = bytes32(uint256(0x123));

    function setUp() public {
        // Deploy mocks
        eas = new MockEAS();
        usdc = new MockUSDC();

        // Deploy SentinelEAS and authorize the committee to issue warnings
        sentinel = new SentinelEAS(address(eas), warningSchema);
        sentinel.setAuthorizedIssuer(committee1, true);
        sentinel.setAuthorizedIssuer(committee2, true);

        // Deploy GrantEscrow
        escrow = new GrantEscrow();

        // Setup committee
        address[] memory committee = new address[](2);
        committee[0] = committee1;
        committee[1] = committee2;

        // Setup milestone
        GrantEscrow.MilestoneInput[] memory milestones = new GrantEscrow.MilestoneInput[](1);
        milestones[0] = GrantEscrow.MilestoneInput({
            title: "Test Milestone",
            description: "Test",
            amount: 1000e6,
            deadline: block.timestamp + 30 days, // Future deadline initially
            proofType: GrantEscrow.ProofType.EASOnly
        });

        // Initialize escrow
        escrow.initialize(
            address(usdc),
            address(0), // registry
            address(sentinel),
            address(0), // superfluid
            address(0), // verifier
            grantor,
            grantee,
            false, // not streaming
            committee,
            1, // quorum
            milestones,
            grantId
        );

        // Fund escrow
        usdc.mint(address(escrow), 1000e6);
    }

    function testSlashRequiresWarning() public {
        // Make milestone overdue
        vm.warp(block.timestamp + 31 days);

        vm.prank(committee1);
        vm.expectRevert("Valid warning required (24h+ old)");
        escrow.slashMilestone(0);
    }

    function testSlashAfterWarning() public {
        // Make milestone overdue
        vm.warp(block.timestamp + 31 days);

        // Issue warning
        vm.prank(committee1);
        sentinel.issueWarning(grantId, 0, grantee, "Milestone overdue");

        // Try to slash immediately - should fail
        vm.prank(committee1);
        vm.expectRevert("Valid warning required (24h+ old)");
        escrow.slashMilestone(0);

        // Wait 24 hours
        vm.warp(block.timestamp + 24 hours + 1);

        // Now slash should work
        uint256 grantorBalanceBefore = usdc.balanceOf(grantor);

        vm.prank(committee1);
        escrow.slashMilestone(0);

        // Verify funds returned
        assertEq(usdc.balanceOf(grantor), grantorBalanceBefore + 1000e6);

        // Verify milestone state
        assertEq(uint256(escrow.getMilestoneStatus(0)), uint256(GrantEscrow.MilestoneState.Slashed));
    }

    function testWarningExpiry() public {
        // Make milestone overdue
        vm.warp(block.timestamp + 31 days);

        // Issue warning
        vm.prank(committee1);
        sentinel.issueWarning(grantId, 0, grantee, "Milestone overdue");

        // Wait 8 days (past 7 day expiry)
        vm.warp(block.timestamp + 8 days);

        // Slash should fail - warning expired
        vm.prank(committee1);
        vm.expectRevert("Valid warning required (24h+ old)");
        escrow.slashMilestone(0);
    }

    function testOnlyCommitteeCanSlash() public {
        // Make milestone overdue
        vm.warp(block.timestamp + 31 days);

        // Issue warning
        vm.prank(committee1);
        sentinel.issueWarning(grantId, 0, grantee, "Milestone overdue");

        // Wait 24 hours
        vm.warp(block.timestamp + 24 hours + 1);

        // Non-committee member tries to slash
        vm.prank(address(0x999));
        vm.expectRevert("Only committee member");
        escrow.slashMilestone(0);

        // Committee member can slash
        vm.prank(committee1);
        escrow.slashMilestone(0);
    }
}
