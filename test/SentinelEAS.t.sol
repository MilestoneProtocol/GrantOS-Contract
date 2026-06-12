// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/SentinelEAS.sol";

contract MockEAS {
    function attest(IEAS.AttestationRequest calldata request) external returns (bytes32) {
        return keccak256(abi.encodePacked(block.timestamp, msg.sender, request.data.recipient));
    }

    function getAttestation(bytes32) external pure returns (IEAS.Attestation memory a) {
        return a;
    }
}

contract SentinelEASTest is Test {
    SentinelEAS sentinel;
    MockEAS eas;

    address owner = address(this); // deployer
    address issuer = address(0x1551E2); // authorized issuer (e.g. committee/keeper)
    address grantee = address(0xB0B); // the party trying to evade slashing
    address stranger = address(0xBAD);

    bytes32 grantId = bytes32(uint256(1));
    bytes32 schema = bytes32(uint256(0x123));

    function setUp() public {
        eas = new MockEAS();
        sentinel = new SentinelEAS(address(eas), schema);
        sentinel.setAuthorizedIssuer(issuer, true);
    }

    // ── Ownership / authorization management ─────────────────────────────────

    function test_deployerIsOwner() public view {
        assertEq(sentinel.owner(), owner);
    }

    function test_setAuthorizedIssuer_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert("Not owner");
        sentinel.setAuthorizedIssuer(stranger, true);
    }

    function test_transferOwnership() public {
        sentinel.transferOwnership(issuer);
        assertEq(sentinel.owner(), issuer);
        // old owner can no longer manage
        vm.expectRevert("Not owner");
        sentinel.setAuthorizedIssuer(stranger, true);
    }

    function test_transferOwnership_rejectsZero() public {
        vm.expectRevert("Zero owner");
        sentinel.transferOwnership(address(0));
    }

    // ── issueWarning access control ──────────────────────────────────────────

    function test_issueWarning_revertsForUnauthorized() public {
        vm.prank(stranger);
        vm.expectRevert("Not authorized issuer");
        sentinel.issueWarning(grantId, 0, grantee, "overdue");
    }

    function test_issueWarning_granteeCannotSelfWarn() public {
        // a grantee planting/forging warnings is exactly what we must prevent
        vm.prank(grantee);
        vm.expectRevert("Not authorized issuer");
        sentinel.issueWarning(grantId, 0, grantee, "overdue");
    }

    function test_issueWarning_authorizedSucceeds() public {
        vm.prank(issuer);
        sentinel.issueWarning(grantId, 0, grantee, "overdue");
        (, uint64 ts, address who, bool active) = sentinel.warnings(grantId, 0);
        assertEq(who, issuer);
        assertTrue(active);
        assertEq(ts, uint64(block.timestamp));
    }

    // ── Anti-reset guard (timestamp griefing) ────────────────────────────────

    /// An authorized issuer (or anyone) must NOT be able to reset a maturing
    /// warning's timestamp by re-issuing, which would push it back under 24h.
    function test_issueWarning_cannotResetActiveWarning() public {
        vm.prank(issuer);
        sentinel.issueWarning(grantId, 0, grantee, "overdue");

        vm.warp(block.timestamp + 20 hours); // maturing toward the 24h slash window

        vm.prank(issuer);
        vm.expectRevert("Active warning exists");
        sentinel.issueWarning(grantId, 0, grantee, "overdue again");
    }

    /// Re-issuing IS allowed once the prior warning expired (>= 7 days).
    function test_issueWarning_reissueAfterExpiry() public {
        vm.prank(issuer);
        sentinel.issueWarning(grantId, 0, grantee, "overdue");

        vm.warp(block.timestamp + 7 days);

        vm.prank(issuer);
        sentinel.issueWarning(grantId, 0, grantee, "re-warn");
        (, uint64 ts,,) = sentinel.warnings(grantId, 0);
        assertEq(ts, uint64(block.timestamp), "timestamp refreshed after expiry");
    }

    /// Re-issuing IS allowed after the prior warning was deactivated.
    function test_issueWarning_reissueAfterDeactivation() public {
        vm.startPrank(issuer);
        sentinel.issueWarning(grantId, 0, grantee, "overdue");
        sentinel.deactivateWarning(grantId, 0);
        sentinel.issueWarning(grantId, 0, grantee, "re-warn");
        vm.stopPrank();
        (,,, bool active) = sentinel.warnings(grantId, 0);
        assertTrue(active);
    }

    // ── deactivateWarning access control ─────────────────────────────────────

    /// The core finding: the grantee must NOT be able to deactivate the warning
    /// that gates slashing.
    function test_deactivateWarning_granteeCannot() public {
        vm.prank(issuer);
        sentinel.issueWarning(grantId, 0, grantee, "overdue");

        vm.prank(grantee);
        vm.expectRevert("Not authorized");
        sentinel.deactivateWarning(grantId, 0);

        (,,, bool active) = sentinel.warnings(grantId, 0);
        assertTrue(active, "warning must remain active");
    }

    function test_deactivateWarning_strangerCannot() public {
        vm.prank(issuer);
        sentinel.issueWarning(grantId, 0, grantee, "overdue");

        vm.prank(stranger);
        vm.expectRevert("Not authorized");
        sentinel.deactivateWarning(grantId, 0);
    }

    function test_deactivateWarning_issuerCan() public {
        vm.startPrank(issuer);
        sentinel.issueWarning(grantId, 0, grantee, "overdue");
        sentinel.deactivateWarning(grantId, 0);
        vm.stopPrank();
        (,,, bool active) = sentinel.warnings(grantId, 0);
        assertFalse(active);
    }

    function test_deactivateWarning_ownerCan() public {
        vm.prank(issuer);
        sentinel.issueWarning(grantId, 0, grantee, "overdue");
        // owner (this contract) can deactivate too
        sentinel.deactivateWarning(grantId, 0);
        (,,, bool active) = sentinel.warnings(grantId, 0);
        assertFalse(active);
    }

    // ── hasValidWarning window behavior ──────────────────────────────────────

    function test_hasValidWarning_window() public {
        vm.prank(issuer);
        sentinel.issueWarning(grantId, 0, grantee, "overdue");

        assertFalse(sentinel.hasValidWarning(grantId, 0), "not valid before 24h");
        vm.warp(block.timestamp + 24 hours + 1);
        assertTrue(sentinel.hasValidWarning(grantId, 0), "valid in window");
        vm.warp(block.timestamp + 7 days);
        assertFalse(sentinel.hasValidWarning(grantId, 0), "expired after 7d");
    }

    function test_getWarningAge() public {
        assertEq(sentinel.getWarningAge(grantId, 0), 0, "no warning -> age 0");
        vm.prank(issuer);
        sentinel.issueWarning(grantId, 0, grantee, "overdue");
        vm.warp(block.timestamp + 3 hours);
        assertEq(sentinel.getWarningAge(grantId, 0), 3 hours);
        // deactivated -> age reads 0
        vm.prank(issuer);
        sentinel.deactivateWarning(grantId, 0);
        assertEq(sentinel.getWarningAge(grantId, 0), 0, "deactivated -> age 0");
    }

    function test_hasValidWarning_noWarning() public view {
        assertFalse(sentinel.hasValidWarning(grantId, 7), "absent warning is never valid");
    }

    // ── Fuzz: only authorized issuers ever mutate warning state ──────────────

    function testFuzz_onlyAuthorizedCanIssue(address caller) public {
        vm.assume(caller != issuer);
        vm.prank(caller);
        vm.expectRevert("Not authorized issuer");
        sentinel.issueWarning(grantId, 0, grantee, "x");
    }

    function testFuzz_onlyIssuerOrOwnerCanDeactivate(address caller) public {
        vm.prank(issuer);
        sentinel.issueWarning(grantId, 0, grantee, "overdue");

        vm.assume(caller != issuer && caller != owner);
        vm.prank(caller);
        vm.expectRevert("Not authorized");
        sentinel.deactivateWarning(grantId, 0);

        (,,, bool active) = sentinel.warnings(grantId, 0);
        assertTrue(active, "warning stays active for any unauthorized caller");
    }
}
