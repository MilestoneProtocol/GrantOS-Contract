// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/GrantEscrow.sol";
import "../src/SentinelEAS.sol";

contract SMUSDC {
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

contract SMSablier {
    uint256 public nextId = 1;

    function createWithDurations(ISablierV2LockupLinear.CreateWithDurations calldata p)
        external
        returns (uint256 streamId)
    {
        require(IERC20(p.asset).transferFrom(msg.sender, address(this), p.totalAmount), "pull failed");
        return nextId++;
    }

    function cancel(uint256) external {}
}

contract SMEAS {
    function attest(IEAS.AttestationRequest calldata r) external returns (bytes32) {
        return keccak256(abi.encodePacked(block.timestamp, msg.sender, r.data.recipient));
    }

    function getAttestation(bytes32) external pure returns (IEAS.Attestation memory a) {
        return a;
    }
}

contract SlashMilestoneTest is Test {
    SMUSDC usdc;
    SMSablier sablier;
    SMEAS eas;
    SentinelEAS sentinel;

    address grantor = address(0xA11CE);
    address grantee = address(0xB0B);
    address committee1 = address(0xC1);
    address committee2 = address(0xC2);
    address stranger = address(0xBAD);

    bytes32 constant GRANT_ID = bytes32(uint256(42));
    uint256 constant DAY = 1 days;

    function setUp() public {
        vm.warp(1_000_000); // non-zero baseline for deadline math
        usdc = new SMUSDC();
        sablier = new SMSablier();
        eas = new SMEAS();
        sentinel = new SentinelEAS(address(eas), bytes32(uint256(0x123)));
        sentinel.setAuthorizedIssuer(committee1, true);
    }

    function _grant(bool streaming, uint256 a0, uint256 a1, uint256 deadline) internal returns (GrantEscrow esc) {
        esc = new GrantEscrow();
        address[] memory committee = new address[](2);
        committee[0] = committee1;
        committee[1] = committee2;
        GrantEscrow.MilestoneInput[] memory ms = new GrantEscrow.MilestoneInput[](2);
        ms[0] = GrantEscrow.MilestoneInput("M0", "d", a0, deadline, GrantEscrow.ProofType.EASOnly);
        ms[1] = GrantEscrow.MilestoneInput("M1", "d", a1, deadline, GrantEscrow.ProofType.EASOnly);
        esc.initialize(
            address(usdc),
            address(0),
            address(sentinel),
            address(sablier),
            address(0), // verifier (EASOnly milestones)
            grantor,
            grantee,
            streaming,
            committee,
            1,
            ms,
            GRANT_ID
        );
        usdc.mint(address(esc), a0 + a1);
    }

    function _submit(GrantEscrow esc, uint256 id) internal {
        vm.prank(grantee);
        esc.submitMilestone(id, "", new bytes32[](0), bytes32(0), "summary");
    }

    function _warn(uint256 id) internal {
        vm.prank(committee1);
        sentinel.issueWarning(GRANT_ID, id, grantee, "overdue");
    }

    function _slash(GrantEscrow esc, uint256 id) internal {
        vm.prank(committee1);
        esc.slashMilestone(id);
    }

    // ── Happy path ───────────────────────────────────────────────────────────

    function test_slash_pendingOverdue() public {
        uint256 deadline = block.timestamp + 10 * DAY;
        GrantEscrow esc = _grant(false, 100e6, 200e6, deadline);

        vm.warp(deadline + 1); // overdue
        _warn(0);
        vm.warp(block.timestamp + 24 hours + 1); // warning matured, still overdue

        uint256 before = usdc.balanceOf(grantor);
        _slash(esc, 0);

        assertEq(usdc.balanceOf(grantor), before + 100e6, "grantor refunded milestone amount");
        assertEq(uint256(esc.getMilestoneStatus(0)), uint256(GrantEscrow.MilestoneState.Slashed));
        assertEq(usdc.balanceOf(address(esc)), 200e6, "other milestone funds untouched");
    }

    // ── #6: on-time Submitted must NOT be slashable ──────────────────────────

    function test_slash_onTimeSubmittedReverts() public {
        uint256 deadline = block.timestamp + 10 * DAY;
        GrantEscrow esc = _grant(false, 100e6, 200e6, deadline);

        _submit(esc, 0); // submitted on time (submittedAt < deadline)

        vm.warp(deadline + 1);
        _warn(0);
        vm.warp(block.timestamp + 24 hours + 1);

        vm.prank(committee1);
        vm.expectRevert("On-time submission under review");
        esc.slashMilestone(0);
    }

    // A late submission (after the deadline) IS slashable.
    function test_slash_lateSubmittedSucceeds() public {
        uint256 deadline = block.timestamp + 10 * DAY;
        GrantEscrow esc = _grant(false, 100e6, 200e6, deadline);

        vm.warp(deadline + 1); // past deadline
        _submit(esc, 0); // submittedAt > deadline
        _warn(0);
        vm.warp(block.timestamp + 24 hours + 1);

        uint256 before = usdc.balanceOf(grantor);
        _slash(esc, 0);
        assertEq(usdc.balanceOf(grantor), before + 100e6);
        assertEq(uint256(esc.getMilestoneStatus(0)), uint256(GrantEscrow.MilestoneState.Slashed));
    }

    // ── #5: Streaming / Approved milestones are not slashable ────────────────

    function test_slash_streamingReverts() public {
        uint256 deadline = block.timestamp + 10 * DAY;
        GrantEscrow esc = _grant(true, 100e6, 200e6, deadline);

        _submit(esc, 0);
        vm.prank(committee1);
        esc.approveMilestone(0); // → Streaming
        assertEq(uint256(esc.getMilestoneStatus(0)), uint256(GrantEscrow.MilestoneState.Streaming));

        vm.warp(deadline + 1);
        _warn(0);
        vm.warp(block.timestamp + 24 hours + 1);

        vm.prank(committee1);
        vm.expectRevert("Invalid state for slash");
        esc.slashMilestone(0);
    }

    function test_slash_approvedReverts() public {
        uint256 deadline = block.timestamp + 10 * DAY;
        GrantEscrow esc = _grant(false, 100e6, 200e6, deadline);

        _submit(esc, 0);
        vm.prank(committee1);
        esc.approveMilestone(0); // → Approved, paid to grantee

        vm.warp(deadline + 1);
        _warn(0);
        vm.warp(block.timestamp + 24 hours + 1);

        vm.prank(committee1);
        vm.expectRevert("Invalid state for slash");
        esc.slashMilestone(0);
    }

    // ── Warning + timing guards ──────────────────────────────────────────────

    function test_slash_requiresWarning() public {
        uint256 deadline = block.timestamp + 10 * DAY;
        GrantEscrow esc = _grant(false, 100e6, 200e6, deadline);
        vm.warp(deadline + 1 + 24 hours);
        vm.prank(committee1);
        vm.expectRevert("Valid warning required (24h+ old)");
        esc.slashMilestone(0);
    }

    function test_slash_warningTooFresh() public {
        uint256 deadline = block.timestamp + 10 * DAY;
        GrantEscrow esc = _grant(false, 100e6, 200e6, deadline);
        vm.warp(deadline + 1);
        _warn(0);
        vm.warp(block.timestamp + 1 hours); // < 24h
        vm.prank(committee1);
        vm.expectRevert("Valid warning required (24h+ old)");
        esc.slashMilestone(0);
    }

    function test_slash_warningExpiredReverts() public {
        uint256 deadline = block.timestamp + 10 * DAY;
        GrantEscrow esc = _grant(false, 100e6, 200e6, deadline);
        vm.warp(deadline + 1);
        _warn(0);
        vm.warp(block.timestamp + 8 days); // > 7d expiry
        vm.prank(committee1);
        vm.expectRevert("Valid warning required (24h+ old)");
        esc.slashMilestone(0);
    }

    function test_slash_notOverdueReverts() public {
        uint256 deadline = block.timestamp + 10 * DAY;
        GrantEscrow esc = _grant(false, 100e6, 200e6, deadline);
        _warn(0);
        vm.warp(block.timestamp + 24 hours + 1); // matured warning but deadline not reached
        vm.prank(committee1);
        vm.expectRevert("Milestone not overdue");
        esc.slashMilestone(0);
    }

    function test_slash_onlyCommittee() public {
        uint256 deadline = block.timestamp + 10 * DAY;
        GrantEscrow esc = _grant(false, 100e6, 200e6, deadline);
        vm.warp(deadline + 1);
        _warn(0);
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(stranger);
        vm.expectRevert("Only committee member");
        esc.slashMilestone(0);
    }

    function test_slash_cannotDoubleSlash() public {
        uint256 deadline = block.timestamp + 10 * DAY;
        GrantEscrow esc = _grant(false, 100e6, 200e6, deadline);
        vm.warp(deadline + 1);
        _warn(0);
        vm.warp(block.timestamp + 24 hours + 1);
        _slash(esc, 0);
        vm.prank(committee1);
        vm.expectRevert("Invalid state for slash"); // Slashed is terminal
        esc.slashMilestone(0);
    }

    // ── Fuzz: a Submitted milestone is slashable iff it was submitted late ────

    function testFuzz_submittedSlashableIffLate(uint256 submitDelay) public {
        uint256 deadline = block.timestamp + 10 * DAY;
        GrantEscrow esc = _grant(false, 100e6, 200e6, deadline);

        submitDelay = bound(submitDelay, 1, 20 * DAY);
        vm.warp(block.timestamp + submitDelay);
        bool late = block.timestamp > deadline; // submittedAt > deadline
        _submit(esc, 0);

        if (block.timestamp <= deadline) vm.warp(deadline + 1); // ensure overdue for the slash attempt
        _warn(0);
        vm.warp(block.timestamp + 24 hours + 1);

        if (late) {
            uint256 before = usdc.balanceOf(grantor);
            _slash(esc, 0);
            assertEq(usdc.balanceOf(grantor), before + 100e6, "late submission slashed");
        } else {
            vm.prank(committee1);
            vm.expectRevert("On-time submission under review");
            esc.slashMilestone(0);
        }
    }
}
