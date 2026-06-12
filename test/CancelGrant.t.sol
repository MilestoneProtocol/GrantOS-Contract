// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/GrantEscrow.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Mocks
// ─────────────────────────────────────────────────────────────────────────────

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

/// @dev Models Sablier: on create it pulls `totalAmount` from the caller (the
///      escrow); on cancel it refunds the *unstreamed* remainder back to the
///      original sender (the escrow). `streamedBps` lets a test simulate how
///      much had already streamed to the recipient before cancellation.
contract MockSablier {
    uint256 public nextId = 1;
    mapping(uint256 => uint256) public deposited;
    mapping(uint256 => address) public sender;
    mapping(uint256 => address) public asset;
    mapping(uint256 => address) public recipient;
    uint256 public streamedBps; // 0..10_000 of each stream considered already delivered

    function setStreamedBps(uint256 bps) external {
        require(bps <= 10_000, "bps");
        streamedBps = bps;
    }

    function createWithDurations(ISablierV2LockupLinear.CreateWithDurations calldata p)
        external
        returns (uint256 streamId)
    {
        require(IERC20(p.asset).transferFrom(msg.sender, address(this), p.totalAmount), "pull failed");
        streamId = nextId++;
        deposited[streamId] = p.totalAmount;
        sender[streamId] = msg.sender;
        asset[streamId] = p.asset;
        recipient[streamId] = p.recipient;
    }

    function cancel(uint256 streamId) external {
        uint256 amt = deposited[streamId];
        if (amt == 0) return;
        deposited[streamId] = 0;
        uint256 streamed = (amt * streamedBps) / 10_000;
        uint256 unstreamed = amt - streamed;
        // streamed portion stays claimable by recipient; unstreamed refunds to escrow
        if (streamed > 0) require(IERC20(asset[streamId]).transfer(recipient[streamId], streamed), "stream pay");
        if (unstreamed > 0) require(IERC20(asset[streamId]).transfer(sender[streamId], unstreamed), "refund");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

contract CancelGrantTest is Test {
    address grantor = address(0xA11CE);
    address grantee = address(0xB0B);
    address c1 = address(0xC1);
    address c2 = address(0xC2);

    MockUSDC usdc;
    MockSablier sablier;

    function setUp() public {
        // fresh mocks are also created per-helper-call for fuzz isolation
        usdc = new MockUSDC();
        sablier = new MockSablier();
    }

    // Build + fund a fresh escrow with its own token + sablier (isolated state).
    function _deploy(bool streaming, uint256[] memory amounts)
        internal
        returns (GrantEscrow esc, MockUSDC token, MockSablier sab, uint256 total)
    {
        token = new MockUSDC();
        sab = new MockSablier();
        esc = new GrantEscrow();

        address[] memory committee = new address[](2);
        committee[0] = c1;
        committee[1] = c2;

        GrantEscrow.MilestoneInput[] memory ms = new GrantEscrow.MilestoneInput[](amounts.length);
        for (uint256 i; i < amounts.length; i++) {
            ms[i] = GrantEscrow.MilestoneInput({
                title: "t",
                description: "d",
                amount: amounts[i],
                deadline: block.timestamp + 30 days,
                proofType: GrantEscrow.ProofType.EASOnly
            });
            total += amounts[i];
        }

        esc.initialize(
            address(token),
            address(0), // registry (unused for EASOnly)
            address(0), // sentinel (unused by cancel)
            address(sab),
            address(0), // verifier (unused for EASOnly)
            grantor,
            grantee,
            streaming,
            committee,
            1, // quorum: a single approval pays/streams
            ms,
            bytes32(uint256(1))
        );
        token.mint(address(esc), total);
    }

    // Submit (grantee) then approve to quorum (one committee vote) → Approved or Streaming.
    function _approve(GrantEscrow esc, uint256 id) internal {
        vm.prank(grantee);
        esc.submitMilestone(id, "", new bytes32[](0), bytes32(0), "summary");
        vm.prank(c1);
        esc.approveMilestone(id);
    }

    // Core conservation assertion shared by every case.
    function _assertConserved(GrantEscrow esc, MockUSDC token, MockSablier sab, uint256 total) internal view {
        assertEq(token.balanceOf(address(esc)), 0, "escrow must be drained after cancel");
        uint256 sum = token.balanceOf(grantor) + token.balanceOf(grantee) + token.balanceOf(address(sab));
        assertEq(sum, total, "USDC must be conserved across grantor/grantee/sablier");
    }

    // ── Regression: the exact double-count scenario ──────────────────────────

    /// Lump-sum, all milestones Pending. Pre-fix this reverted (refund = 2x balance).
    function test_cancel_lumpSum_allPending() public {
        uint256[] memory a = new uint256[](2);
        a[0] = 100e6;
        a[1] = 200e6;
        (GrantEscrow esc, MockUSDC token, MockSablier sab, uint256 total) = _deploy(false, a);

        vm.prank(grantor);
        esc.cancelGrant();

        assertEq(token.balanceOf(grantor), 300e6, "grantor reclaims full unspent balance");
        _assertConserved(esc, token, sab, total);
    }

    /// Lump-sum, one approved (funds left to grantee) + one pending.
    function test_cancel_lumpSum_oneApprovedOnePending() public {
        uint256[] memory a = new uint256[](2);
        a[0] = 100e6;
        a[1] = 200e6;
        (GrantEscrow esc, MockUSDC token, MockSablier sab, uint256 total) = _deploy(false, a);

        _approve(esc, 0); // 100e6 → grantee

        vm.prank(grantor);
        esc.cancelGrant();

        assertEq(token.balanceOf(grantee), 100e6, "approved milestone already paid");
        assertEq(token.balanceOf(grantor), 200e6, "grantor reclaims only the remaining milestone");
        _assertConserved(esc, token, sab, total);
    }

    // ── The case the user asked about: streaming-only ────────────────────────

    /// Streaming grant, one approved (now Streaming, funds in Sablier) + one Pending.
    /// This is the scenario where "just use streaming" was hoped to dodge the bug.
    function test_cancel_streaming_oneStreamingOnePending() public {
        uint256[] memory a = new uint256[](2);
        a[0] = 100e6;
        a[1] = 200e6;
        (GrantEscrow esc, MockUSDC token, MockSablier sab, uint256 total) = _deploy(true, a);

        _approve(esc, 0); // 100e6 pulled into Sablier as a stream
        assertEq(token.balanceOf(address(sab)), 100e6, "stream funded");
        assertEq(token.balanceOf(address(esc)), 200e6, "only pending milestone remains in escrow");

        vm.prank(grantor);
        esc.cancelGrant();

        // stream cancelled & fully refunded (0% streamed) → grantor gets 100 + 200
        assertEq(token.balanceOf(grantor), 300e6, "grantor reclaims pending + refunded stream");
        _assertConserved(esc, token, sab, total);
    }

    /// Streaming grant where part of the stream already flowed to the builder.
    function test_cancel_streaming_partiallyStreamed() public {
        uint256[] memory a = new uint256[](2);
        a[0] = 100e6;
        a[1] = 200e6;
        (GrantEscrow esc, MockUSDC token, MockSablier sab, uint256 total) = _deploy(true, a);

        sab.setStreamedBps(4_000); // 40% already delivered to grantee
        _approve(esc, 0);

        vm.prank(grantor);
        esc.cancelGrant();

        assertEq(token.balanceOf(grantee), 40e6, "40% of the stream stays with the builder");
        assertEq(token.balanceOf(grantor), 260e6, "grantor gets pending 200 + unstreamed 60");
        _assertConserved(esc, token, sab, total);
    }

    /// Degenerate case that worked even pre-fix: every milestone already streaming.
    function test_cancel_streaming_allStreaming() public {
        uint256[] memory a = new uint256[](2);
        a[0] = 100e6;
        a[1] = 200e6;
        (GrantEscrow esc, MockUSDC token, MockSablier sab, uint256 total) = _deploy(true, a);

        _approve(esc, 0);
        _approve(esc, 1);
        assertEq(token.balanceOf(address(esc)), 0, "all funds pulled into Sablier");

        vm.prank(grantor);
        esc.cancelGrant();

        assertEq(token.balanceOf(grantor), 300e6, "both streams refunded to grantor");
        _assertConserved(esc, token, sab, total);
    }

    // ── Fuzz: conservation across arbitrary shapes ───────────────────────────

    /// Fuzz lump-sum grants: random count, amounts, and approval mask.
    /// Invariant: cancel never reverts, drains the escrow, and conserves USDC.
    function testFuzz_cancel_lumpSum(uint96[8] memory rawAmounts, uint8 count, uint8 approveMask) public {
        uint256 n = bound(count, 1, 8);
        uint256[] memory a = new uint256[](n);
        for (uint256 i; i < n; i++) {
            a[i] = bound(uint256(rawAmounts[i]), 1, 1e12);
        }

        (GrantEscrow esc, MockUSDC token, MockSablier sab, uint256 total) = _deploy(false, a);

        for (uint256 i; i < n; i++) {
            if ((approveMask >> uint8(i)) & 1 == 1) {
                _approve(esc, i); // pays grantee, funds leave escrow
            }
        }

        vm.prank(grantor);
        esc.cancelGrant(); // must not revert

        _assertConserved(esc, token, sab, total);
    }

    /// Fuzz streaming grants: random count, amounts, approval mask, and how much
    /// of each stream had already flowed. Same conservation invariant.
    function testFuzz_cancel_streaming(
        uint96[8] memory rawAmounts,
        uint8 count,
        uint8 approveMask,
        uint16 streamedBps
    ) public {
        uint256 n = bound(count, 1, 8);
        uint256[] memory a = new uint256[](n);
        for (uint256 i; i < n; i++) {
            a[i] = bound(uint256(rawAmounts[i]), 1, 1e12);
        }

        (GrantEscrow esc, MockUSDC token, MockSablier sab, uint256 total) = _deploy(true, a);
        sab.setStreamedBps(bound(streamedBps, 0, 10_000));

        for (uint256 i; i < n; i++) {
            if ((approveMask >> uint8(i)) & 1 == 1) {
                _approve(esc, i); // funds pulled into Sablier as a stream
            }
        }

        vm.prank(grantor);
        esc.cancelGrant(); // must not revert

        _assertConserved(esc, token, sab, total);
    }
}
