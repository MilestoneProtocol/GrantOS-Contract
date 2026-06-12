// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import "../../src/GrantEscrow.sol";
import "../../src/GrantFactory.sol";
import "../../src/SentinelEAS.sol";

// ── Mocks ───────────────────────────────────────────────────────────────────

contract MGUSDC {
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

contract MGSablier {
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

contract MGEAS {
    function attest(IEAS.AttestationRequest calldata r) external returns (bytes32) {
        return keccak256(abi.encodePacked(block.timestamp, msg.sender, r.data.recipient));
    }
    function getAttestation(bytes32) external pure returns (IEAS.Attestation memory a) { return a; }
}

// ── Handler: drives many concurrent grants through the factory ──────────────

contract FactoryHandler {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    uint256 constant MAX_GRANTS = 6;

    MGUSDC public usdc;
    GrantFactory public factory;
    SentinelEAS public sentinel;
    address[3] public grantors;
    address[3] public grantees;
    address[3] public committee;

    address[] public escrows;
    bytes32[] public grantIds;
    mapping(address => address) public granteeOf;
    mapping(address => uint256) public deadlineOf;

    uint256 public totalMinted;

    constructor(
        MGUSDC _usdc,
        GrantFactory _factory,
        SentinelEAS _sentinel,
        address[3] memory _grantors,
        address[3] memory _grantees,
        address[3] memory _committee
    ) {
        usdc = _usdc;
        factory = _factory;
        sentinel = _sentinel;
        grantors = _grantors;
        grantees = _grantees;
        committee = _committee;
    }

    function numGrants() external view returns (uint256) { return escrows.length; }

    function createGrant(uint256 gSeed, uint256 eSeed, uint256 amtSeed, uint8 nMsSeed, bool streaming) external {
        if (escrows.length >= MAX_GRANTS) return;
        address gr = grantors[gSeed % 3];
        address ge = grantees[eSeed % 3];
        uint256 n = (nMsSeed % 3) + 1; // 1..3 milestones
        uint256 deadline = block.timestamp + 30 days;

        GrantEscrow.MilestoneInput[] memory ms = new GrantEscrow.MilestoneInput[](n);
        uint256 total;
        for (uint256 i; i < n; i++) {
            uint256 a = (uint256(keccak256(abi.encode(amtSeed, i))) % 1e12) + 1;
            ms[i] = GrantEscrow.MilestoneInput("M", "d", a, deadline, GrantEscrow.ProofType.EASOnly);
            total += a;
        }

        address[] memory com = new address[](3);
        com[0] = committee[0];
        com[1] = committee[1];
        com[2] = committee[2];

        usdc.mint(gr, total);
        totalMinted += total;

        vm.startPrank(gr);
        usdc.approve(address(factory), total);
        try factory.createGrant(ge, streaming, com, 2, ms) returns (uint256 gid, address esc) {
            escrows.push(esc);
            grantIds.push(bytes32(gid));
            granteeOf[esc] = ge;
            deadlineOf[esc] = deadline;
        } catch {
            // creation failed: undo the mint accounting so conservation stays exact
            totalMinted -= total;
        }
        vm.stopPrank();
    }

    function submit(uint256 gSeed, uint256 idSeed) external {
        if (escrows.length == 0) return;
        address esc = escrows[gSeed % escrows.length];
        uint256 id = idSeed % GrantEscrow(esc).getMilestoneCount();
        vm.prank(granteeOf[esc]);
        try GrantEscrow(esc).submitMilestone(id, "", new bytes32[](0), bytes32(0), "s") {} catch {}
    }

    function approve(uint256 gSeed, uint256 idSeed, uint256 vSeed) external {
        if (escrows.length == 0) return;
        address esc = escrows[gSeed % escrows.length];
        uint256 id = idSeed % GrantEscrow(esc).getMilestoneCount();
        vm.prank(committee[vSeed % 3]);
        try GrantEscrow(esc).approveMilestone(id) {} catch {}
    }

    function reject(uint256 gSeed, uint256 idSeed, uint256 vSeed) external {
        if (escrows.length == 0) return;
        address esc = escrows[gSeed % escrows.length];
        uint256 id = idSeed % GrantEscrow(esc).getMilestoneCount();
        vm.prank(committee[vSeed % 3]);
        try GrantEscrow(esc).rejectMilestone(id) {} catch {}
    }

    function warnAndSlash(uint256 gSeed, uint256 idSeed) external {
        if (escrows.length == 0) return;
        uint256 gi = gSeed % escrows.length;
        address esc = escrows[gi];
        uint256 id = idSeed % GrantEscrow(esc).getMilestoneCount();
        GrantEscrow.MilestoneState s = GrantEscrow(esc).getMilestoneStatus(id);
        if (
            s != GrantEscrow.MilestoneState.Pending && s != GrantEscrow.MilestoneState.Submitted
                && s != GrantEscrow.MilestoneState.Rejected
        ) return;

        if (block.timestamp <= deadlineOf[esc]) vm.warp(deadlineOf[esc] + 1);
        if (!sentinel.hasValidWarning(grantIds[gi], id)) {
            try sentinel.issueWarning(grantIds[gi], id, granteeOf[esc], "overdue") {} catch {}
            vm.warp(block.timestamp + 24 hours + 1);
        }
        vm.prank(committee[0]);
        try GrantEscrow(esc).slashMilestone(id) {} catch {}
    }

    function cancel(uint256 gSeed) external {
        if (escrows.length == 0) return;
        uint256 gi = gSeed % escrows.length;
        // grantor of a grant is whichever address funded it; cancel is onlyGrantor,
        // so try each grantor (only the real one succeeds).
        for (uint256 j; j < 3; j++) {
            vm.prank(grantors[j]);
            try GrantEscrow(escrows[gi]).cancelGrant() { break; } catch {}
        }
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + (dt % 60 days) + 1);
    }
}

// ── Invariant test ──────────────────────────────────────────────────────────

contract FactoryMultiGrantTest is Test {
    MGUSDC usdc;
    MGSablier sablier;
    MGEAS eas;
    SentinelEAS sentinel;
    GrantFactory factory;
    FactoryHandler handler;

    address[3] grantors = [address(0xA1), address(0xA2), address(0xA3)];
    address[3] grantees = [address(0xB1), address(0xB2), address(0xB3)];
    address[3] committee = [address(0xC0), address(0xC1), address(0xC2)];

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MGUSDC();
        sablier = new MGSablier();
        eas = new MGEAS();
        sentinel = new SentinelEAS(address(eas), bytes32(uint256(1)));

        GrantEscrow impl = new GrantEscrow();
        factory = new GrantFactory(
            address(impl), address(usdc), address(0), address(sentinel), address(sablier), address(0)
        );

        handler = new FactoryHandler(usdc, factory, sentinel, grantors, grantees, committee);
        sentinel.setAuthorizedIssuer(address(handler), true);

        targetContract(address(handler));
    }

    // GLOBAL conservation: every USDC ever minted is accounted for across all
    // grants and actors. If one grant's funds ever leaked into another, this sum
    // (or per-grant solvency below) would break.
    function invariant_globalConservation() public view {
        uint256 sum = usdc.balanceOf(address(sablier)) + usdc.balanceOf(address(factory))
            + usdc.balanceOf(address(handler));
        for (uint256 i; i < 3; i++) {
            sum += usdc.balanceOf(grantors[i]);
            sum += usdc.balanceOf(grantees[i]);
            sum += usdc.balanceOf(committee[i]);
        }
        uint256 n = handler.numGrants();
        for (uint256 i; i < n; i++) sum += usdc.balanceOf(handler.escrows(i));
        assertEq(sum, handler.totalMinted(), "global USDC conserved across all grants");
    }

    // CROSS-GRANT ISOLATION: each escrow holds EXACTLY its own unpaid obligations.
    // A leak in either direction (A funding B, or B draining A) would make some
    // escrow's balance != its own owed amount.
    function invariant_perGrantIsolation() public view {
        uint256 n = handler.numGrants();
        for (uint256 i; i < n; i++) {
            GrantEscrow esc = GrantEscrow(handler.escrows(i));
            uint256 owed;
            uint256 m = esc.getMilestoneCount();
            for (uint256 j; j < m; j++) {
                GrantEscrow.MilestoneState s = esc.getMilestoneStatus(j);
                if (
                    s == GrantEscrow.MilestoneState.Pending || s == GrantEscrow.MilestoneState.Submitted
                        || s == GrantEscrow.MilestoneState.Rejected
                ) {
                    (,, uint256 amount,,,) = esc.milestones(j);
                    owed += amount;
                }
            }
            assertEq(usdc.balanceOf(address(esc)), owed, "escrow isolated: holds exactly its own owed funds");
        }
    }

    // The factory itself is a pure router and must never hold funds.
    function invariant_factoryHoldsNothing() public view {
        assertEq(usdc.balanceOf(address(factory)), 0, "factory never custodies funds");
    }

    // grantCount only ever grows and matches the grants the handler tracks.
    function invariant_grantCountMonotone() public view {
        assertGe(factory.grantCount(), handler.numGrants(), "factory grantCount >= tracked grants");
    }
}
