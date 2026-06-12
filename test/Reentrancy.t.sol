// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/GrantEscrow.sol";

/// @dev An ERC20 that calls a registered receiver's hook after a transfer
///      (ERC777-style), giving a malicious recipient a chance to re-enter.
contract HookToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public hookReceiver;

    function setHook(address r) external { hookReceiver = r; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }

    function _move(address f, address t, uint256 a) internal {
        require(balanceOf[f] >= a, "bal");
        balanceOf[f] -= a;
        balanceOf[t] += a;
        if (t == hookReceiver && t.code.length > 0) {
            ReentrantActor(t).onTokenReceived(a);
        }
    }

    function transfer(address t, uint256 a) external returns (bool) { _move(msg.sender, t, a); return true; }
    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        require(allowance[f][msg.sender] >= a, "allow");
        allowance[f][msg.sender] -= a;
        _move(f, t, a);
        return true;
    }
}

/// @dev A malicious actor that can hold grantee/committee/grantor roles and, on
///      receiving tokens, re-enters a chosen escrow function.
contract ReentrantActor {
    GrantEscrow public esc;
    uint8 public mode; // 1=approve, 2=cancel, 3=slash
    uint256 public idx;
    bool armed;

    bool public didReenter;
    bool public reentryReverted;
    string public reentryReason;

    function arm(GrantEscrow _e, uint8 _m, uint256 _i) external { esc = _e; mode = _m; idx = _i; armed = true; }

    function onTokenReceived(uint256) external {
        if (!armed) return;
        armed = false; // one-shot, avoid infinite recursion
        didReenter = true;

        bytes memory cd;
        if (mode == 1) cd = abi.encodeWithSelector(GrantEscrow.approveMilestone.selector, idx);
        else if (mode == 2) cd = abi.encodeWithSelector(GrantEscrow.cancelGrant.selector);
        else cd = abi.encodeWithSelector(GrantEscrow.slashMilestone.selector, idx);

        (bool ok, bytes memory ret) = address(esc).call(cd);
        if (!ok) {
            reentryReverted = true;
            reentryReason = _reason(ret);
        }
    }

    function _reason(bytes memory ret) internal pure returns (string memory) {
        if (ret.length < 68) return "";
        assembly { ret := add(ret, 0x04) }
        return abi.decode(ret, (string));
    }

    // helpers to act in the actor's privileged roles
    function submit(GrantEscrow _e, uint256 i) external {
        _e.submitMilestone(i, "", new bytes32[](0), bytes32(0), "s");
    }
    function approve(GrantEscrow _e, uint256 i) external { _e.approveMilestone(i); }
    function cancel(GrantEscrow _e) external { _e.cancelGrant(); }
}

contract ReentrancyTest is Test {
    HookToken token;
    ReentrantActor actor;
    address c2 = address(0xC2);

    function setUp() public {
        token = new HookToken();
        actor = new ReentrantActor();
        token.setHook(address(actor));
    }

    // build a grant where `actor` is grantee + a committee member (quorum 1)
    function _grantActorAsBuilder() internal returns (GrantEscrow esc) {
        esc = new GrantEscrow();
        address[] memory com = new address[](2);
        com[0] = address(actor);
        com[1] = c2;
        GrantEscrow.MilestoneInput[] memory ms = new GrantEscrow.MilestoneInput[](1);
        ms[0] = GrantEscrow.MilestoneInput("M", "d", 100e6, block.timestamp + 30 days, GrantEscrow.ProofType.EASOnly);
        esc.initialize(address(token), address(0), address(0), address(0), address(0),
            address(0xDEAD), address(actor), false, com, 1, ms, bytes32(uint256(1)));
        token.mint(address(esc), 100e6);
    }

    // ── The nonReentrant guard fires on same-function reentry ────────────────

    function test_guard_blocksReentrantApprove() public {
        GrantEscrow esc = _grantActorAsBuilder();
        actor.submit(esc, 0);
        actor.arm(esc, 1, 0); // on payout, re-enter approveMilestone(0)

        actor.approve(esc, 0); // quorum 1 -> pays grantee(actor) -> hook -> reentry

        assertTrue(actor.didReenter(), "reentry was attempted");
        assertTrue(actor.reentryReverted(), "reentry was blocked");
        assertEq(actor.reentryReason(), "ReentrancyGuard: reentrant call", "blocked by the guard");
        // and the protected effect happened exactly once
        assertEq(uint256(esc.getMilestoneStatus(0)), uint256(GrantEscrow.MilestoneState.Approved));
        assertEq(token.balanceOf(address(actor)), 100e6, "paid exactly once, no double-spend");
        assertEq(token.balanceOf(address(esc)), 0);
    }

    function test_guard_blocksReentrantSlashDuringApprove() public {
        GrantEscrow esc = _grantActorAsBuilder();
        actor.submit(esc, 0);
        actor.arm(esc, 3, 0); // re-enter slashMilestone(0) (actor is a committee member)

        actor.approve(esc, 0);

        assertTrue(actor.reentryReverted());
        // guard fires before slash's overdue/warning checks are even reached
        assertEq(actor.reentryReason(), "ReentrancyGuard: reentrant call");
        assertEq(uint256(esc.getMilestoneStatus(0)), uint256(GrantEscrow.MilestoneState.Approved));
        assertEq(token.balanceOf(address(actor)), 100e6);
    }

    // ── Access control is the outer line of defense for cross-fn reentry ─────

    function test_accessControl_blocksReentrantCancelByCommittee() public {
        GrantEscrow esc = _grantActorAsBuilder();
        actor.submit(esc, 0);
        actor.arm(esc, 2, 0); // re-enter cancelGrant — but actor is NOT the grantor

        actor.approve(esc, 0);

        assertTrue(actor.reentryReverted());
        assertEq(actor.reentryReason(), "Only grantor", "cross-fn reentry stopped by access control");
        // grant is NOT cancelled; milestone paid normally
        assertEq(uint256(esc.getMilestoneStatus(0)), uint256(GrantEscrow.MilestoneState.Approved));
        assertEq(token.balanceOf(address(actor)), 100e6);
    }

    // ── Reentry into cancelGrant by the grantor cannot double-refund ─────────

    function test_grantor_cannotDoubleRefundViaReentry() public {
        // actor is the grantor and receives the refund -> hook -> reentry cancelGrant
        GrantEscrow esc = new GrantEscrow();
        address[] memory com = new address[](2);
        com[0] = address(0xC1);
        com[1] = c2;
        GrantEscrow.MilestoneInput[] memory ms = new GrantEscrow.MilestoneInput[](1);
        ms[0] = GrantEscrow.MilestoneInput("M", "d", 100e6, block.timestamp + 30 days, GrantEscrow.ProofType.EASOnly);
        esc.initialize(address(token), address(0), address(0), address(0), address(0),
            address(actor), address(0xB0B), false, com, 1, ms, bytes32(uint256(1)));
        token.mint(address(esc), 100e6);

        actor.arm(esc, 2, 0); // re-enter cancelGrant during the refund payout
        actor.cancel(esc);

        assertTrue(actor.reentryReverted(), "nested cancel blocked");
        // notCancelled (cancelled already true) or the guard stops it; either way no double refund
        assertEq(token.balanceOf(address(actor)), 100e6, "refunded exactly once");
        assertEq(token.balanceOf(address(esc)), 0, "escrow drained once");
    }

    // ── Conservation holds across the reentrancy attempts ────────────────────

    function test_reentrancy_conservation() public {
        GrantEscrow esc = _grantActorAsBuilder();
        actor.submit(esc, 0);
        actor.arm(esc, 1, 0);
        actor.approve(esc, 0);
        assertEq(token.balanceOf(address(esc)) + token.balanceOf(address(actor)), 100e6, "no tokens created or lost");
    }
}
