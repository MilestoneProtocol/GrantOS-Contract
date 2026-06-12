// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/GrantEscrow.sol";
import "../src/GrantFactory.sol";

contract VWUSDC {
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

/// @notice Finding #7: the verifier must be wired atomically at init and be
///         immune to an unprivileged installer/swapper. The old unguarded
///         `setVerifier(address)` has been removed.
contract VerifierWiringTest is Test {
    address grantor = address(0xA11CE);
    address grantee = address(0xB0B);
    address c1 = address(0xC1);
    address c2 = address(0xC2);
    address constant VERIFIER = address(0x5E5E); // sentinel verifier address

    function _milestones() internal view returns (GrantEscrow.MilestoneInput[] memory ms) {
        ms = new GrantEscrow.MilestoneInput[](1);
        ms[0] = GrantEscrow.MilestoneInput("M0", "d", 100e6, block.timestamp + 30 days, GrantEscrow.ProofType.EASOnly);
    }

    function _committee() internal view returns (address[] memory c) {
        c = new address[](2);
        c[0] = c1;
        c[1] = c2;
    }

    // ── Direct initialize wires the verifier and it is immutable ─────────────

    function test_initialize_setsVerifier() public {
        GrantEscrow esc = new GrantEscrow();
        esc.initialize(
            address(new VWUSDC()),
            address(0),
            address(0),
            address(0),
            VERIFIER,
            grantor,
            grantee,
            false,
            _committee(),
            1,
            _milestones(),
            bytes32(uint256(1))
        );
        assertEq(address(esc.verifier()), VERIFIER, "verifier wired at init");
    }

    function test_initialize_isOneShot() public {
        GrantEscrow esc = new GrantEscrow();
        esc.initialize(
            address(new VWUSDC()),
            address(0),
            address(0),
            address(0),
            VERIFIER,
            grantor,
            grantee,
            false,
            _committee(),
            1,
            _milestones(),
            bytes32(uint256(1))
        );
        // re-init (e.g. to swap the verifier) must revert. Build args first so
        // the CREATE below doesn't consume the expectRevert.
        address u2 = address(new VWUSDC());
        address[] memory com = _committee();
        GrantEscrow.MilestoneInput[] memory ms = _milestones();
        vm.expectRevert("Already initialized");
        esc.initialize(
            u2,
            address(0),
            address(0),
            address(0),
            address(0xBAD),
            grantor,
            grantee,
            false,
            com,
            1,
            ms,
            bytes32(uint256(2))
        );
        assertEq(address(esc.verifier()), VERIFIER, "verifier unchanged");
    }

    /// The old attack surface is gone: there is no `setVerifier(address)` to call.
    function test_noSetVerifierFunction() public {
        GrantEscrow esc = new GrantEscrow();
        esc.initialize(
            address(new VWUSDC()),
            address(0),
            address(0),
            address(0),
            VERIFIER,
            grantor,
            grantee,
            false,
            _committee(),
            1,
            _milestones(),
            bytes32(uint256(1))
        );
        // a low-level call to the removed selector must NOT succeed (no such fn, no fallback)
        (bool ok,) = address(esc).call(abi.encodeWithSignature("setVerifier(address)", address(0xBAD)));
        assertFalse(ok, "setVerifier must no longer exist");
        assertEq(address(esc.verifier()), VERIFIER, "verifier still immutable");
    }

    // ── Factory path wires the verifier into the clone ───────────────────────

    function test_factory_wiresVerifierIntoClone() public {
        VWUSDC usdc = new VWUSDC();
        GrantEscrow impl = new GrantEscrow();
        GrantFactory factory =
            new GrantFactory(address(impl), address(usdc), address(0), address(0), address(0), VERIFIER);

        usdc.mint(grantor, 100e6);
        vm.startPrank(grantor);
        usdc.approve(address(factory), 100e6);
        (, address escrowAddr) = factory.createGrant(grantee, false, _committee(), 1, _milestones());
        vm.stopPrank();

        assertEq(address(GrantEscrow(escrowAddr).verifier()), VERIFIER, "clone got the factory's verifier");
    }
}
