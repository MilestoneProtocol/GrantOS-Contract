// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/GrantEscrow.sol";
import "../src/GrantFactory.sol";

/// @dev A fee-on-transfer ERC20: every transfer skims `feeBps` to a fee sink, so
///      the recipient always receives less than `amount`. This is the class of
///      non-standard token GrantOS does NOT support (it is built for USDC), and
///      these tests document precisely how the contracts behave when fed one.
contract FeeToken {
    uint256 public feeBps;
    address public constant SINK = address(0xFEE5);
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(uint256 _feeBps) { feeBps = _feeBps; }

    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }

    function _move(address f, address t, uint256 a) internal {
        require(balanceOf[f] >= a, "bal");
        uint256 fee = (a * feeBps) / 10_000;
        balanceOf[f] -= a;
        balanceOf[t] += a - fee;
        balanceOf[SINK] += fee;
    }

    function transfer(address t, uint256 a) external returns (bool) { _move(msg.sender, t, a); return true; }
    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        require(allowance[f][msg.sender] >= a, "allow");
        allowance[f][msg.sender] -= a;
        _move(f, t, a);
        return true;
    }
}

contract NoopSablier {
    uint256 public nextId = 1;
    function createWithDurations(ISablierV2LockupLinear.CreateWithDurations calldata p) external returns (uint256) {
        require(IERC20(p.asset).transferFrom(msg.sender, address(this), p.totalAmount), "pull");
        return nextId++;
    }
    function cancel(uint256) external {}
}

contract FeeOnTransferTokenTest is Test {
    FeeToken token;        // 1% fee
    NoopSablier sablier;
    GrantFactory factory;

    address grantor = address(0xA11CE);
    address grantee = address(0xB0B);
    address c1 = address(0xC0);
    address c2 = address(0xC1);
    address constant SINK = address(0xFEE5);

    function setUp() public {
        token = new FeeToken(100); // 1%
        sablier = new NoopSablier();
        GrantEscrow impl = new GrantEscrow();
        factory = new GrantFactory(
            address(impl), address(token), address(0), address(0), address(sablier), address(0)
        );
    }

    function _committee() internal view returns (address[] memory c) {
        c = new address[](2);
        c[0] = c1;
        c[1] = c2;
    }

    function _ms(uint256[] memory amounts) internal view returns (GrantEscrow.MilestoneInput[] memory ms) {
        ms = new GrantEscrow.MilestoneInput[](amounts.length);
        for (uint256 i; i < amounts.length; i++) {
            ms[i] = GrantEscrow.MilestoneInput("M", "d", amounts[i], block.timestamp + 30 days, GrantEscrow.ProofType.EASOnly);
        }
    }

    function _create(uint256[] memory amounts) internal returns (GrantEscrow esc, uint256 total) {
        for (uint256 i; i < amounts.length; i++) total += amounts[i];
        token.mint(grantor, total);
        vm.startPrank(grantor);
        token.approve(address(factory), total);
        (, address e) = factory.createGrant(grantee, false, _committee(), 1, _ms(amounts));
        vm.stopPrank();
        esc = GrantEscrow(e);
    }

    function _amts(uint256 a) internal pure returns (uint256[] memory x) { x = new uint256[](1); x[0] = a; }

    // ── Funding under-delivers ───────────────────────────────────────────────

    /// The factory pulls `total` but the escrow receives `total - fee`; the
    /// milestone is still recorded at the full nominal amount -> under-funded.
    function test_funding_underfundsEscrow() public {
        (GrantEscrow esc, uint256 total) = _create(_amts(100e6));
        assertEq(token.balanceOf(address(esc)), 99e6, "escrow short by the 1% fee");
        assertEq(token.balanceOf(SINK), 1e6, "fee captured by sink");
        assertLt(token.balanceOf(address(esc)), total, "escrow under-funded vs obligations");
    }

    // ── Payout path reverts safely (no loss) ─────────────────────────────────

    /// Approving a milestone tries to transfer the FULL nominal amount, but the
    /// escrow only holds amount-fee -> the transfer reverts. The milestone is
    /// stuck Submitted; crucially, no funds are lost or mispaid.
    function test_approve_revertsWhenAmountExceedsPostFeeBalance() public {
        (GrantEscrow esc,) = _create(_amts(100e6)); // escrow holds 99e6
        vm.prank(grantee);
        esc.submitMilestone(0, "", new bytes32[](0), bytes32(0), "s");

        vm.prank(c1);
        vm.expectRevert(bytes("bal")); // FeeToken: escrow can't transfer 100e6 from a 99e6 balance
        esc.approveMilestone(0);

        assertEq(uint256(esc.getMilestoneStatus(0)), uint256(GrantEscrow.MilestoneState.Submitted), "still submitted");
        assertEq(token.balanceOf(grantee), 0, "grantee paid nothing");
    }

    /// With multiple milestones, early ones can pay (escrow still has enough) but
    /// the accumulated fees eventually starve a later payout -> partial then stuck.
    function test_partialPayoutsThenStuck() public {
        uint256[] memory a = new uint256[](2);
        a[0] = 40e6;
        a[1] = 60e6; // total 100e6 -> escrow holds 99e6
        (GrantEscrow esc,) = _create(a);

        // milestone 0 (40e6) pays: escrow 99e6 -> 59e6, grantee receives 40e6 - fee
        vm.prank(grantee);
        esc.submitMilestone(0, "", new bytes32[](0), bytes32(0), "s");
        vm.prank(c1);
        esc.approveMilestone(0);
        assertEq(uint256(esc.getMilestoneStatus(0)), uint256(GrantEscrow.MilestoneState.Approved));
        assertEq(token.balanceOf(grantee), 40e6 - 0.4e6, "grantee got amount minus outbound fee");
        assertEq(token.balanceOf(address(esc)), 59e6, "escrow drained by full 40e6");

        // milestone 1 (60e6) cannot pay: escrow holds only 59e6
        vm.prank(grantee);
        esc.submitMilestone(1, "", new bytes32[](0), bytes32(0), "s");
        vm.prank(c1);
        vm.expectRevert(bytes("bal"));
        esc.approveMilestone(1);
    }

    // ── cancelGrant is fee-robust (balance-based refund) ─────────────────────

    /// The hardened cancelGrant refunds `balanceOf(escrow)` rather than nominal
    /// milestone sums, so it works under a fee token: it returns whatever the
    /// escrow actually holds, no revert.
    function test_cancel_refundsActualBalance_noRevert() public {
        (GrantEscrow esc,) = _create(_amts(100e6)); // escrow holds 99e6
        uint256 before = token.balanceOf(grantor);

        vm.prank(grantor);
        esc.cancelGrant(); // must not revert

        // grantor receives the escrow's 99e6 minus the outbound 1% fee
        assertEq(token.balanceOf(grantor), before + (99e6 - 0.99e6), "refund = actual balance minus fee");
        assertEq(token.balanceOf(address(esc)), 0, "escrow drained");
    }

    // ── Nothing vanishes: full conservation including the fee sink ───────────

    function test_conservation_includingFeeSink() public {
        (GrantEscrow esc, uint256 total) = _create(_amts(100e6));
        vm.prank(grantor);
        esc.cancelGrant();

        uint256 sum = token.balanceOf(address(esc)) + token.balanceOf(grantee)
            + token.balanceOf(grantor) + token.balanceOf(SINK) + token.balanceOf(address(sablier));
        assertEq(sum, total, "every token accounted for (fees in sink, none lost)");
    }

    // ── Fuzz: any non-zero fee makes a full-balance milestone unpayable ──────

    function testFuzz_anyFeeBreaksFullAmountPayout(uint256 feeBps, uint256 amount) public {
        feeBps = bound(feeBps, 1, 1000); // 0.01% .. 10%
        amount = bound(amount, 1e6, 1e12);

        FeeToken ft = new FeeToken(feeBps);
        GrantEscrow impl = new GrantEscrow();
        GrantFactory f = new GrantFactory(address(impl), address(ft), address(0), address(0), address(sablier), address(0));

        ft.mint(grantor, amount);
        vm.startPrank(grantor);
        ft.approve(address(f), amount);
        (, address e) = f.createGrant(grantee, false, _committee(), 1, _ms(_amts(amount)));
        vm.stopPrank();

        GrantEscrow esc = GrantEscrow(e);
        // escrow received amount - fee, strictly less than the milestone's amount
        assertLt(ft.balanceOf(address(esc)), amount);

        vm.prank(grantee);
        esc.submitMilestone(0, "", new bytes32[](0), bytes32(0), "s");
        vm.prank(c1);
        vm.expectRevert(bytes("bal"));
        esc.approveMilestone(0);
    }
}
