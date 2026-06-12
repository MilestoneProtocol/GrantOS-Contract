// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/GrantEscrow.sol";

contract VUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) {
        require(balanceOf[msg.sender] >= a, "bal"); balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        require(balanceOf[f] >= a, "bal"); require(allowance[f][msg.sender] >= a, "allow");
        balanceOf[f] -= a; balanceOf[t] += a; allowance[f][msg.sender] -= a; return true;
    }
}

contract VSablier {
    uint256 public nextId = 1;
    mapping(uint256 => uint256) public amt;
    mapping(uint256 => address) public from;
    mapping(uint256 => address) public asset;
    function createWithDurations(ISablierV2LockupLinear.CreateWithDurations calldata p) external returns (uint256 id) {
        require(IERC20(p.asset).transferFrom(msg.sender, address(this), p.totalAmount), "pull");
        id = nextId++; amt[id] = p.totalAmount; from[id] = msg.sender; asset[id] = p.asset;
    }
    function cancel(uint256 id) external {
        uint256 a = amt[id]; amt[id] = 0;
        if (a > 0) require(IERC20(asset[id]).transfer(from[id], a), "refund");
    }
}

contract VotingTest is Test {
    VUSDC usdc;
    VSablier sablier;
    address grantor = address(0xA11CE);
    address grantee = address(0xB0B);
    address[7] cmt = [
        address(0xC0), address(0xC1), address(0xC2), address(0xC3),
        address(0xC4), address(0xC5), address(0xC6)
    ];

    function setUp() public {
        usdc = new VUSDC();
        sablier = new VSablier();
    }

    function _escrow(bool streaming, uint256 nCommittee, uint256 quorum, uint256[] memory amounts)
        internal
        returns (GrantEscrow esc, uint256 total)
    {
        esc = new GrantEscrow();
        address[] memory committee = new address[](nCommittee);
        for (uint256 i; i < nCommittee; i++) committee[i] = cmt[i];
        GrantEscrow.MilestoneInput[] memory ms = new GrantEscrow.MilestoneInput[](amounts.length);
        for (uint256 i; i < amounts.length; i++) {
            ms[i] = GrantEscrow.MilestoneInput("M", "d", amounts[i], block.timestamp + 30 days, GrantEscrow.ProofType.EASOnly);
            total += amounts[i];
        }
        esc.initialize(address(usdc), address(0), address(0), address(sablier), address(0),
            grantor, grantee, streaming, committee, quorum, ms, bytes32(uint256(1)));
        usdc.mint(address(esc), total);
    }

    function _one(uint256 amount) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = amount;
    }

    function _submit(GrantEscrow esc, uint256 id) internal {
        vm.prank(grantee);
        esc.submitMilestone(id, "", new bytes32[](0), bytes32(0), "s");
    }

    // ── submitMilestone ──────────────────────────────────────────────────────

    function test_submit_onlyGrantee() public {
        (GrantEscrow esc,) = _escrow(false, 2, 1, _one(100e6));
        vm.prank(address(0xDEAD));
        vm.expectRevert("Only grantee");
        esc.submitMilestone(0, "", new bytes32[](0), bytes32(0), "s");
    }

    function test_submit_invalidId() public {
        (GrantEscrow esc,) = _escrow(false, 2, 1, _one(100e6));
        vm.prank(grantee);
        vm.expectRevert("Invalid milestone");
        esc.submitMilestone(5, "", new bytes32[](0), bytes32(0), "s");
    }

    function test_submit_setsSubmitted() public {
        (GrantEscrow esc,) = _escrow(false, 2, 1, _one(100e6));
        _submit(esc, 0);
        assertEq(uint256(esc.getMilestoneStatus(0)), uint256(GrantEscrow.MilestoneState.Submitted));
        assertEq(esc.getSubmission(0).submittedAt, block.timestamp);
    }

    function test_submit_cannotResubmitWhileSubmitted() public {
        (GrantEscrow esc,) = _escrow(false, 2, 1, _one(100e6));
        _submit(esc, 0);
        vm.prank(grantee);
        vm.expectRevert("Invalid state for submission");
        esc.submitMilestone(0, "", new bytes32[](0), bytes32(0), "s");
    }

    // ── approveMilestone: quorum + payout ────────────────────────────────────

    function test_approve_onlyCommittee() public {
        (GrantEscrow esc,) = _escrow(false, 2, 1, _one(100e6));
        _submit(esc, 0);
        vm.prank(address(0xDEAD));
        vm.expectRevert("Only committee member");
        esc.approveMilestone(0);
    }

    function test_approve_notSubmitted() public {
        (GrantEscrow esc,) = _escrow(false, 2, 1, _one(100e6));
        vm.prank(cmt[0]);
        vm.expectRevert("Not submitted");
        esc.approveMilestone(0);
    }

    function test_approve_doubleVoteRejected() public {
        (GrantEscrow esc,) = _escrow(false, 3, 2, _one(100e6));
        _submit(esc, 0);
        vm.prank(cmt[0]);
        esc.approveMilestone(0);
        vm.prank(cmt[0]);
        vm.expectRevert("Already voted");
        esc.approveMilestone(0);
    }

    function test_approve_belowQuorumDoesNotPay() public {
        (GrantEscrow esc,) = _escrow(false, 3, 2, _one(100e6)); // quorum 2
        _submit(esc, 0);
        vm.prank(cmt[0]);
        esc.approveMilestone(0); // 1 of 2
        assertEq(uint256(esc.getMilestoneStatus(0)), uint256(GrantEscrow.MilestoneState.Submitted));
        assertEq(usdc.balanceOf(grantee), 0);
    }

    function test_approve_quorumPaysLumpSum() public {
        (GrantEscrow esc,) = _escrow(false, 3, 2, _one(100e6));
        _submit(esc, 0);
        vm.prank(cmt[0]);
        esc.approveMilestone(0);
        vm.prank(cmt[1]);
        esc.approveMilestone(0); // quorum reached
        assertEq(uint256(esc.getMilestoneStatus(0)), uint256(GrantEscrow.MilestoneState.Approved));
        assertEq(usdc.balanceOf(grantee), 100e6);
        assertEq(usdc.balanceOf(address(esc)), 0);
    }

    function test_approve_quorumStreams() public {
        (GrantEscrow esc,) = _escrow(true, 2, 1, _one(100e6));
        _submit(esc, 0);
        vm.prank(cmt[0]);
        esc.approveMilestone(0);
        assertEq(uint256(esc.getMilestoneStatus(0)), uint256(GrantEscrow.MilestoneState.Streaming));
        assertEq(usdc.balanceOf(address(sablier)), 100e6, "funds streamed to sablier");
        assertEq(usdc.balanceOf(address(esc)), 0);
        (uint256 active, uint256 amount,) = esc.getStreamingInfo();
        assertEq(active, 1);
        assertEq(amount, 100e6);
    }

    function test_approve_cannotApproveAfterApproved() public {
        (GrantEscrow esc,) = _escrow(false, 2, 1, _one(100e6));
        _submit(esc, 0);
        vm.prank(cmt[0]);
        esc.approveMilestone(0); // quorum 1 -> Approved
        vm.prank(cmt[1]);
        vm.expectRevert("Not submitted");
        esc.approveMilestone(0);
    }

    // ── rejectMilestone: threshold + resubmission ────────────────────────────

    function test_reject_thresholdReturnsToPending() public {
        // committee 3, quorum 2 -> rejectThreshold = 3-2+1 = 2
        (GrantEscrow esc,) = _escrow(false, 3, 2, _one(100e6));
        _submit(esc, 0);
        vm.prank(cmt[0]);
        esc.rejectMilestone(0); // 1 rejection, threshold 2 not reached
        assertEq(uint256(esc.getMilestoneStatus(0)), uint256(GrantEscrow.MilestoneState.Submitted));
        vm.prank(cmt[1]);
        esc.rejectMilestone(0); // 2 rejections -> back to Pending
        assertEq(uint256(esc.getMilestoneStatus(0)), uint256(GrantEscrow.MilestoneState.Pending));
    }

    function test_reject_thenResubmitAndApprove() public {
        (GrantEscrow esc,) = _escrow(false, 3, 2, _one(100e6));
        _submit(esc, 0);
        vm.prank(cmt[0]);
        esc.rejectMilestone(0);
        vm.prank(cmt[1]);
        esc.rejectMilestone(0); // back to Pending, votes reset
        // resubmit
        _submit(esc, 0);
        // prior rejecter can now approve (votes were reset)
        vm.prank(cmt[0]);
        esc.approveMilestone(0);
        vm.prank(cmt[1]);
        esc.approveMilestone(0);
        assertEq(uint256(esc.getMilestoneStatus(0)), uint256(GrantEscrow.MilestoneState.Approved));
        assertEq(usdc.balanceOf(grantee), 100e6);
    }

    function test_reject_doubleVoteRejected() public {
        (GrantEscrow esc,) = _escrow(false, 3, 2, _one(100e6));
        _submit(esc, 0);
        vm.prank(cmt[0]);
        esc.rejectMilestone(0);
        vm.prank(cmt[0]);
        vm.expectRevert("Already voted");
        esc.rejectMilestone(0);
    }

    function test_unanimousQuorum_singleRejectResets() public {
        // committee 3, quorum 3 -> rejectThreshold = 1
        (GrantEscrow esc,) = _escrow(false, 3, 3, _one(100e6));
        _submit(esc, 0);
        vm.prank(cmt[0]);
        esc.rejectMilestone(0); // 1 rejection >= threshold 1 -> Pending
        assertEq(uint256(esc.getMilestoneStatus(0)), uint256(GrantEscrow.MilestoneState.Pending));
    }

    // ── Fuzz: pays iff approvals reach quorum ────────────────────────────────

    function testFuzz_paysIffQuorumApprovals(uint256 nC, uint256 q, uint256 approvals) public {
        nC = bound(nC, 2, 7);
        q = bound(q, 1, nC);
        approvals = bound(approvals, 0, nC);

        (GrantEscrow esc,) = _escrow(false, nC, q, _one(100e6));
        _submit(esc, 0);

        bool paid;
        for (uint256 i; i < approvals; i++) {
            // stop voting once paid (state leaves Submitted)
            if (esc.getMilestoneStatus(0) != GrantEscrow.MilestoneState.Submitted) break;
            vm.prank(cmt[i]);
            esc.approveMilestone(0);
            if (esc.getMilestoneStatus(0) == GrantEscrow.MilestoneState.Approved) paid = true;
        }
        assertEq(paid, approvals >= q, "pays iff approvals reached quorum");
        assertEq(usdc.balanceOf(grantee), approvals >= q ? 100e6 : 0);
    }

    // ── Fuzz: returns to Pending iff rejections reach threshold ───────────────

    function testFuzz_resetsIffRejectThreshold(uint256 nC, uint256 q, uint256 rejects) public {
        nC = bound(nC, 2, 7);
        q = bound(q, 1, nC);
        rejects = bound(rejects, 0, nC);
        uint256 threshold = nC - q + 1;

        (GrantEscrow esc,) = _escrow(false, nC, q, _one(100e6));
        _submit(esc, 0);

        bool reset;
        for (uint256 i; i < rejects; i++) {
            if (esc.getMilestoneStatus(0) != GrantEscrow.MilestoneState.Submitted) break;
            vm.prank(cmt[i]);
            esc.rejectMilestone(0);
            if (esc.getMilestoneStatus(0) == GrantEscrow.MilestoneState.Pending) reset = true;
        }
        assertEq(reset, rejects >= threshold, "resets iff rejections reached threshold");
    }
}
