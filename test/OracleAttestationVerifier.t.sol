// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/OracleAttestationVerifier.sol";
import "../src/GrantIdentityRegistry.sol";

contract OracleAttestationVerifierTest is Test {
    OracleAttestationVerifier verifier;

    uint256 oraclePk = 0xA11CE;
    address oracle;
    uint256 attackerPk = 0xBADBEEF;

    // secp256k1 group order
    uint256 constant N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    function setUp() public {
        oracle = vm.addr(oraclePk);
        verifier = new OracleAttestationVerifier(oracle);
    }

    function _inputs(uint256 tier, uint256 githubId, uint256 year, address wallet)
        internal
        pure
        returns (bytes32[] memory pi)
    {
        pi = new bytes32[](5);
        pi[0] = bytes32(tier);
        pi[1] = bytes32(githubId);
        pi[2] = bytes32(year);
        pi[3] = bytes32(0); // wallet hi
        pi[4] = bytes32(uint256(uint160(wallet))); // wallet lo
    }

    function _sign(uint256 pk, bytes32[] memory pi) internal view returns (bytes memory) {
        bytes32 h = verifier.attestationHash(pi);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, h);
        return abi.encodePacked(r, s, v);
    }

    // ── Construction ─────────────────────────────────────────────────────────

    function test_oracleSet() public view {
        assertEq(verifier.oracle(), oracle);
    }

    function test_constructor_rejectsZeroOracle() public {
        vm.expectRevert(OracleAttestationVerifier.InvalidOracle.selector);
        new OracleAttestationVerifier(address(0));
    }

    // ── Core verification ────────────────────────────────────────────────────

    function test_validOracleSignature() public view {
        bytes32[] memory pi = _inputs(3, 85998029, 2021, address(0xB0B));
        assertTrue(verifier.verify(_sign(oraclePk, pi), pi));
    }

    function test_wrongSignerRejected() public view {
        bytes32[] memory pi = _inputs(3, 85998029, 2021, address(0xB0B));
        // attacker self-signs — recovers to attacker, not the oracle
        assertFalse(verifier.verify(_sign(attackerPk, pi), pi));
    }

    function test_tamperedTierRejected() public view {
        bytes32[] memory pi = _inputs(1, 85998029, 2021, address(0xB0B));
        bytes memory sig = _sign(oraclePk, pi);
        pi[0] = bytes32(uint256(3)); // upgrade tier 1 -> 3 after signing
        assertFalse(verifier.verify(sig, pi));
    }

    function test_tamperedWalletRejected() public view {
        bytes32[] memory pi = _inputs(3, 85998029, 2021, address(0xB0B));
        bytes memory sig = _sign(oraclePk, pi);
        pi[4] = bytes32(uint256(uint160(address(0xBAD)))); // rebind to attacker wallet
        assertFalse(verifier.verify(sig, pi));
    }

    function test_tamperedGithubIdRejected() public view {
        bytes32[] memory pi = _inputs(3, 85998029, 2021, address(0xB0B));
        bytes memory sig = _sign(oraclePk, pi);
        pi[1] = bytes32(uint256(999)); // steal a different github id
        assertFalse(verifier.verify(sig, pi));
    }

    function test_garbageProofRejected() public view {
        bytes32[] memory pi = _inputs(3, 85998029, 2021, address(0xB0B));
        // the OLD no-op accepted any non-zero blob; now it must fail
        bytes memory blob = new bytes(2048);
        blob[0] = 0x01;
        assertFalse(verifier.verify(blob, pi));
    }

    function test_wrongLengthProofRejected() public view {
        bytes32[] memory pi = _inputs(3, 85998029, 2021, address(0xB0B));
        assertFalse(verifier.verify(new bytes(64), pi)); // 64 != 65
    }

    function test_shortPublicInputsRejected() public view {
        bytes32[] memory pi = new bytes32[](4);
        assertFalse(verifier.verify(new bytes(65), pi));
    }

    function test_malleableHighSRejected() public view {
        bytes32[] memory pi = _inputs(3, 85998029, 2021, address(0xB0B));
        bytes32 h = verifier.attestationHash(pi);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(oraclePk, h);
        // Flip to the malleable counterpart: s' = N - s, v' = v ^ 1 -> high-s, must be rejected
        bytes32 sHigh = bytes32(N - uint256(s));
        uint8 vFlip = v == 27 ? 28 : 27;
        assertFalse(verifier.verify(abi.encodePacked(r, sHigh, vFlip), pi), "high-s must be rejected");
        // sanity: the canonical low-s form still verifies
        assertTrue(verifier.verify(abi.encodePacked(r, s, v), pi));
    }

    // ── Fuzz: only the oracle key produces accepted signatures ───────────────

    function testFuzz_onlyOracleKeySigns(uint256 pk) public view {
        pk = bound(pk, 1, N - 1);
        bytes32[] memory pi = _inputs(2, 12345, 2019, address(0xCAFE));
        bool isOracle = vm.addr(pk) == oracle;
        assertEq(verifier.verify(_sign(pk, pi), pi), isOracle);
    }

    // ── Integration: the GrantIdentityRegistry forgery is now closed ─────────

    function test_registry_legitAttestationRegisters() public {
        GrantIdentityRegistry registry = new GrantIdentityRegistry(address(verifier));
        address user = address(0xB0B);
        bytes32[] memory pi = _inputs(3, 85998029, 2021, user);
        bytes memory sig = _sign(oraclePk, pi);

        vm.prank(user);
        registry.verifyIdentity(sig, pi, "octocat");

        assertTrue(registry.isVerified(user));
        assertEq(registry.getIdentity(user).tier, 3);
    }

    function test_registry_forgedTierRejected() public {
        GrantIdentityRegistry registry = new GrantIdentityRegistry(address(verifier));
        address attacker = address(0xBAD);
        // attacker fabricates tier-3 inputs bound to their own wallet, self-signs
        bytes32[] memory pi = _inputs(3, 85998029, 2021, attacker);
        bytes memory sig = _sign(attackerPk, pi);

        vm.prank(attacker);
        vm.expectRevert("Invalid ZK proof"); // registry's require(verifier.verify(...))
        registry.verifyIdentity(sig, pi, "imposter");

        assertFalse(registry.isVerified(attacker));
    }

    function test_registry_garbageProofRejected() public {
        GrantIdentityRegistry registry = new GrantIdentityRegistry(address(verifier));
        address attacker = address(0xBAD);
        bytes32[] memory pi = _inputs(3, 85998029, 2021, attacker);
        bytes memory blob = new bytes(2048); // the kind of blob the no-op accepted
        blob[0] = 0x01;

        vm.prank(attacker);
        vm.expectRevert("Invalid ZK proof");
        registry.verifyIdentity(blob, pi, "imposter");
    }
}
