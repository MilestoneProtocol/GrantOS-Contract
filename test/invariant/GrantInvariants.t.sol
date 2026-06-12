// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import "../../src/GrantEscrow.sol";
import "../../src/SentinelEAS.sol";

// ── Mocks ───────────────────────────────────────────────────────────────────

contract InvUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        require(balanceOf[msg.sender] >= a, "bal");
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        require(balanceOf[f] >= a, "bal");
        require(allowance[f][msg.sender] >= a, "allow");
        balanceOf[f] -= a;
        balanceOf[t] += a;
        allowance[f][msg.sender] -= a;
        return true;
    }
}

contract InvSablier {
    uint256 public nextId = 1;
    mapping(uint256 => uint256) public amt;
    mapping(uint256 => address) public from;
    mapping(uint256 => address) public asset;

    function createWithDurations(ISablierV2LockupLinear.CreateWithDurations calldata p) external returns (uint256 id) {
        require(IERC20(p.asset).transferFrom(msg.sender, address(this), p.totalAmount), "pull");
        id = nextId++;
        amt[id] = p.totalAmount;
        from[id] = msg.sender;
        asset[id] = p.asset;
    }

    function cancel(uint256 id) external {
        uint256 a = amt[id];
        amt[id] = 0;
        if (a > 0) require(IERC20(asset[id]).transfer(from[id], a), "refund");
    }
}

contract InvEAS {
    function attest(IEAS.AttestationRequest calldata r) external returns (bytes32) {
        return keccak256(abi.encodePacked(block.timestamp, msg.sender, r.data.recipient));
    }

    function getAttestation(bytes32) external pure returns (IEAS.Attestation memory a) {
        return a;
    }
}

// ── Handler: drives the full protocol with random actions ───────────────────

contract GrantHandler {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    GrantEscrow public esc;
    SentinelEAS public sentinel;
    bytes32 public grantId;
    uint256 public deadline;
    address public grantor;
    address public grantee;
    address[] public committee;

    // call-count telemetry
    uint256 public submits;
    uint256 public approves;
    uint256 public rejects;
    uint256 public slashes;
    uint256 public cancels;

    constructor(
        GrantEscrow _esc,
        SentinelEAS _sentinel,
        bytes32 _grantId,
        uint256 _deadline,
        address _grantor,
        address _grantee,
        address[] memory _committee
    ) {
        esc = _esc;
        sentinel = _sentinel;
        grantId = _grantId;
        deadline = _deadline;
        grantor = _grantor;
        grantee = _grantee;
        committee = _committee;
    }

    function _n() internal view returns (uint256) {
        return esc.getMilestoneCount();
    }

    function submit(uint256 idSeed) external {
        uint256 id = idSeed % _n();
        vm.prank(grantee);
        try esc.submitMilestone(id, "", new bytes32[](0), bytes32(0), "s") {
            submits++;
        } catch {}
    }

    function approve(uint256 idSeed, uint256 voterSeed) external {
        uint256 id = idSeed % _n();
        address voter = committee[voterSeed % committee.length];
        vm.prank(voter);
        try esc.approveMilestone(id) {
            approves++;
        } catch {}
    }

    function reject(uint256 idSeed, uint256 voterSeed) external {
        uint256 id = idSeed % _n();
        address voter = committee[voterSeed % committee.length];
        vm.prank(voter);
        try esc.rejectMilestone(id) {
            rejects++;
        } catch {}
    }

    function warnAndSlash(uint256 idSeed) external {
        uint256 id = idSeed % _n();
        GrantEscrow.MilestoneState s = esc.getMilestoneStatus(id);
        if (
            s != GrantEscrow.MilestoneState.Pending && s != GrantEscrow.MilestoneState.Submitted
                && s != GrantEscrow.MilestoneState.Rejected
        ) return;

        if (block.timestamp <= deadline) vm.warp(deadline + 1);
        if (!sentinel.hasValidWarning(grantId, id)) {
            try sentinel.issueWarning(grantId, id, grantee, "overdue") {} catch {}
            vm.warp(block.timestamp + 24 hours + 1);
        }
        vm.prank(committee[0]);
        try esc.slashMilestone(id) {
            slashes++;
        } catch {}
    }

    function cancel() external {
        vm.prank(grantor);
        try esc.cancelGrant() {
            cancels++;
        } catch {}
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + (dt % 60 days) + 1);
    }
}

// ── Invariant base ──────────────────────────────────────────────────────────

abstract contract GrantInvariantBase is Test {
    InvUSDC usdc;
    InvSablier sablier;
    InvEAS eas;
    SentinelEAS sentinel;
    GrantEscrow esc;
    GrantHandler handler;

    address grantor = address(0xA11CE);
    address grantee = address(0xB0B);
    bytes32 constant GID = bytes32(uint256(7));
    uint256 totalFunded;

    function _streaming() internal pure virtual returns (bool);

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new InvUSDC();
        sablier = new InvSablier();
        eas = new InvEAS();
        sentinel = new SentinelEAS(address(eas), bytes32(uint256(1)));

        address[] memory committee = new address[](3);
        committee[0] = address(0xC0);
        committee[1] = address(0xC1);
        committee[2] = address(0xC2);

        // 3 milestones of varied sizes
        uint256[3] memory amts = [uint256(100e6), 250e6, 50e6];
        GrantEscrow.MilestoneInput[] memory ms = new GrantEscrow.MilestoneInput[](3);
        uint256 deadline = block.timestamp + 30 days;
        for (uint256 i; i < 3; i++) {
            ms[i] = GrantEscrow.MilestoneInput("M", "d", amts[i], deadline, GrantEscrow.ProofType.EASOnly);
            totalFunded += amts[i];
        }

        esc = new GrantEscrow();
        esc.initialize(
            address(usdc),
            address(0),
            address(sentinel),
            address(sablier),
            address(0),
            grantor,
            grantee,
            _streaming(),
            committee,
            2,
            ms,
            GID
        );
        usdc.mint(address(esc), totalFunded);

        handler = new GrantHandler(esc, sentinel, GID, deadline, grantor, grantee, committee);
        sentinel.setAuthorizedIssuer(address(handler), true);

        targetContract(address(handler));
    }

    // Total USDC is conserved across every actor at all times.
    function invariant_conservation() public view {
        uint256 sum = usdc.balanceOf(address(esc)) + usdc.balanceOf(grantee) + usdc.balanceOf(grantor)
            + usdc.balanceOf(address(sablier));
        assertEq(sum, totalFunded, "USDC conservation");
    }

    // The escrow always holds exactly the funds it still owes (unpaid milestones).
    function invariant_solvency() public view {
        uint256 owed;
        uint256 n = esc.getMilestoneCount();
        for (uint256 i; i < n; i++) {
            GrantEscrow.MilestoneState s = esc.getMilestoneStatus(i);
            if (
                s == GrantEscrow.MilestoneState.Pending || s == GrantEscrow.MilestoneState.Submitted
                    || s == GrantEscrow.MilestoneState.Rejected
            ) {
                (,, uint256 amount,,,) = esc.milestones(i);
                owed += amount;
            }
        }
        assertEq(usdc.balanceOf(address(esc)), owed, "escrow holds exactly what it owes");
    }

    // Vote tallies can never exceed the committee size.
    function invariant_voteBounds() public view {
        uint256 n = esc.getMilestoneCount();
        for (uint256 i; i < n; i++) {
            GrantEscrow.Submission memory sub = esc.getSubmission(i);
            assertLe(sub.approvalCount, 3, "approvals <= committee");
            assertLe(sub.rejectionCount, 3, "rejections <= committee");
        }
    }

    // A grantee can never be paid more than the grant total.
    function invariant_noOverpay() public view {
        assertLe(usdc.balanceOf(grantee), totalFunded, "grantee never overpaid");
        assertLe(usdc.balanceOf(grantor), totalFunded, "grantor never over-refunded");
    }
}

contract GrantInvariantLumpSum is GrantInvariantBase {
    function _streaming() internal pure override returns (bool) {
        return false;
    }
}

contract GrantInvariantStreaming is GrantInvariantBase {
    function _streaming() internal pure override returns (bool) {
        return true;
    }
}
