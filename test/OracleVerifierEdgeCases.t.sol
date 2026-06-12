// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/OracleAttestationVerifier.sol";
import "../src/GrantIdentityRegistry.sol";

/// @notice Exhaustive edge-case coverage for OracleAttestationVerifier:
///         signature format, ecrecover quirks, malleability boundary,
///         public-input shapes, value extremes, domain/prefix binding,
///         multi-oracle isolation, and registry integration corners.
contract OracleVerifierEdgeCasesTest is Test {
    OracleAttestationVerifier verifier;

    uint256 oraclePk = uint256(keccak256("oracle"));
    address oracle;
    uint256 otherPk = uint256(keccak256("other"));

    uint256 constant N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    uint256 constant N_HALF = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    function setUp() public {
        oracle = vm.addr(oraclePk);
        verifier = new OracleAttestationVerifier(oracle);
    }

    // helpers ----------------------------------------------------------------

    function _pi(uint256 tier, uint256 gid, uint256 year, bytes32 hi, bytes32 lo)
        internal
        pure
        returns (bytes32[] memory pi)
    {
        pi = new bytes32[](5);
        pi[0] = bytes32(tier);
        pi[1] = bytes32(gid);
        pi[2] = bytes32(year);
        pi[3] = hi;
        pi[4] = lo;
    }

    function _piWallet(uint256 tier, uint256 gid, uint256 year, address w) internal pure returns (bytes32[] memory) {
        // full address packed: hi = top 32 bits, lo = bottom 128 bits
        uint256 a = uint160(w);
        return _pi(tier, gid, year, bytes32(a >> 128), bytes32(a & ((uint256(1) << 128) - 1)));
    }

    function _rsv(uint256 pk, bytes32[] memory pi) internal view returns (bytes32 r, bytes32 s, uint8 v) {
        (v, r, s) = vm.sign(pk, verifier.attestationHash(pi));
    }

    function _sig(uint256 pk, bytes32[] memory pi) internal view returns (bytes memory) {
        (bytes32 r, bytes32 s, uint8 v) = _rsv(pk, pi);
        return abi.encodePacked(r, s, v);
    }

    // ── A. Signature format ──────────────────────────────────────────────────

    function test_len_zero() public view {
        assertFalse(verifier.verify(new bytes(0), _piWallet(1, 1, 2020, address(1))));
    }

    function test_len_64() public view {
        assertFalse(verifier.verify(new bytes(64), _piWallet(1, 1, 2020, address(1))));
    }

    function test_len_66() public view {
        assertFalse(verifier.verify(new bytes(66), _piWallet(1, 1, 2020, address(1))));
    }

    function test_len_130_concatenatedSigs() public view {
        // two 65-byte sigs concatenated (a sneaky 130-byte blob) must be rejected
        bytes32[] memory pi = _piWallet(1, 1, 2020, address(1));
        bytes memory s = _sig(oraclePk, pi);
        assertFalse(verifier.verify(abi.encodePacked(s, s), pi));
    }

    function test_allZeroSignature() public view {
        assertFalse(verifier.verify(new bytes(65), _piWallet(1, 1, 2020, address(1))));
    }

    // ── B. v (recovery id) handling ──────────────────────────────────────────

    function test_v_normalized_0_and_1() public view {
        bytes32[] memory pi = _piWallet(2, 7, 2019, address(0xB0B));
        (bytes32 r, bytes32 s, uint8 v) = _rsv(oraclePk, pi);
        // backend may emit v in {0,1}; contract normalizes by +27
        uint8 vLegacy = v - 27; // 0 or 1
        assertTrue(verifier.verify(abi.encodePacked(r, s, vLegacy), pi), "v in {0,1} must work");
    }

    function test_v_invalid_values() public view {
        bytes32[] memory pi = _piWallet(2, 7, 2019, address(0xB0B));
        (bytes32 r, bytes32 s,) = _rsv(oraclePk, pi);
        assertFalse(verifier.verify(abi.encodePacked(r, s, uint8(26)), pi), "v=26 -> 53 invalid");
        assertFalse(verifier.verify(abi.encodePacked(r, s, uint8(29)), pi), "v=29 invalid");
        assertFalse(verifier.verify(abi.encodePacked(r, s, uint8(255)), pi), "v=255 invalid");
    }

    function test_v_flipped_recoversWrongSigner() public view {
        bytes32[] memory pi = _piWallet(2, 7, 2019, address(0xB0B));
        (bytes32 r, bytes32 s, uint8 v) = _rsv(oraclePk, pi);
        uint8 vOther = v == 27 ? 28 : 27;
        // flipping only v (not s) recovers a different pubkey -> not the oracle
        assertFalse(verifier.verify(abi.encodePacked(r, s, vOther), pi));
    }

    // ── C. ecrecover degenerate inputs ───────────────────────────────────────

    function test_r_zero() public view {
        bytes32[] memory pi = _piWallet(1, 1, 2020, address(1));
        (, bytes32 s,) = _rsv(oraclePk, pi);
        assertFalse(verifier.verify(abi.encodePacked(bytes32(0), s, uint8(27)), pi));
    }

    function test_s_zero() public view {
        bytes32[] memory pi = _piWallet(1, 1, 2020, address(1));
        (bytes32 r,,) = _rsv(oraclePk, pi);
        assertFalse(verifier.verify(abi.encodePacked(r, bytes32(0), uint8(27)), pi));
    }

    function test_r_aboveCurveOrder() public view {
        bytes32[] memory pi = _piWallet(1, 1, 2020, address(1));
        (, bytes32 s, uint8 v) = _rsv(oraclePk, pi);
        assertFalse(verifier.verify(abi.encodePacked(bytes32(N), s, v), pi));
    }

    // ── D. Malleability boundary (EIP-2 low-s) ───────────────────────────────

    function test_vmSign_isLowS() public view {
        // sanity: cheatcode signatures are already canonical low-s
        (, bytes32 s,) = _rsv(oraclePk, _piWallet(3, 9, 2021, address(0xB0B)));
        assertLe(uint256(s), N_HALF, "vm.sign must produce low-s");
    }

    function test_highS_counterpart_rejected_lowS_accepted() public view {
        bytes32[] memory pi = _piWallet(3, 9, 2021, address(0xB0B));
        (bytes32 r, bytes32 s, uint8 v) = _rsv(oraclePk, pi);
        assertTrue(verifier.verify(abi.encodePacked(r, s, v), pi), "canonical low-s accepted");
        bytes32 sHigh = bytes32(N - uint256(s));
        uint8 vFlip = v == 27 ? 28 : 27;
        assertGt(uint256(sHigh), N_HALF, "counterpart is high-s");
        assertFalse(verifier.verify(abi.encodePacked(r, sHigh, vFlip), pi), "high-s rejected");
    }

    function test_s_justAboveHalf_rejected() public view {
        // a fabricated sig with s = N_HALF+1: even if it recovered the oracle it
        // would be rejected by the low-s guard; here it simply must not pass
        bytes32[] memory pi = _piWallet(1, 1, 2020, address(1));
        (bytes32 r,, uint8 v) = _rsv(oraclePk, pi);
        assertFalse(verifier.verify(abi.encodePacked(r, bytes32(N_HALF + 1), v), pi));
    }

    // ── E. Public-input shape ────────────────────────────────────────────────

    function test_pi_lengthBelow5() public view {
        bytes memory sig = new bytes(65);
        assertFalse(verifier.verify(sig, new bytes32[](0)));
        assertFalse(verifier.verify(sig, new bytes32[](4)));
    }

    function test_pi_extraInputsIgnored() public view {
        // verifier signs only [0..4]; trailing inputs are not part of the
        // attestation and must not affect a valid result (documented behavior).
        bytes32[] memory pi5 = _piWallet(3, 42, 2018, address(0xB0B));
        bytes memory sig = _sig(oraclePk, pi5);

        bytes32[] memory pi7 = new bytes32[](7);
        for (uint256 i; i < 5; i++) {
            pi7[i] = pi5[i];
        }
        pi7[5] = bytes32(uint256(0xDEAD));
        pi7[6] = bytes32(uint256(0xBEEF));
        // attestationHash over a >5 array uses the same first 5 -> same digest
        assertEq(verifier.attestationHash(pi7), verifier.attestationHash(pi5));
        assertTrue(verifier.verify(sig, pi7), "extra inputs ignored, still valid");
    }

    function test_pi_allZero_signedByOracle() public view {
        // all-zero public inputs are a valid message; only the oracle can sign it
        bytes32[] memory pi = new bytes32[](5);
        assertTrue(verifier.verify(_sig(oraclePk, pi), pi));
        assertFalse(verifier.verify(_sig(otherPk, pi), pi));
    }

    // ── F. Value extremes ────────────────────────────────────────────────────

    function test_tier_zero_member() public view {
        bytes32[] memory pi = _piWallet(0, 1, 2008, address(0xB0B));
        assertTrue(verifier.verify(_sig(oraclePk, pi), pi));
    }

    function test_maxGithubId_and_maxFields() public view {
        bytes32[] memory pi = _pi(
            type(uint256).max,
            type(uint256).max,
            type(uint256).max,
            bytes32(type(uint256).max),
            bytes32(type(uint256).max)
        );
        assertTrue(verifier.verify(_sig(oraclePk, pi), pi));
    }

    function test_highBitWallet_packing() public view {
        address w = 0xFeEDC0De1234567890abcdEf1234567890AbCdeF; // high bits set
        bytes32[] memory pi = _piWallet(2, 1, 2020, w);
        assertTrue(uint256(pi[3]) != 0, "hi limb should be non-zero for this address");
        assertTrue(verifier.verify(_sig(oraclePk, pi), pi));
        // and it reconstructs to the real address (matches registry binding math)
        uint160 recon = uint160((uint256(pi[3]) << 128) | uint256(pi[4]));
        assertEq(recon, uint160(w));
    }

    // ── G. Domain / prefix binding ───────────────────────────────────────────

    function test_rawHash_withoutEip191Prefix_rejected() public view {
        bytes32[] memory pi = _piWallet(3, 1, 2020, address(0xB0B));
        bytes32 inner = keccak256(abi.encode(verifier.DOMAIN(), pi[0], pi[1], pi[2], pi[3], pi[4]));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(oraclePk, inner); // signed WITHOUT the prefix
        assertFalse(verifier.verify(abi.encodePacked(r, s, v), pi), "missing EIP-191 prefix must fail");
    }

    function test_wrongDomain_rejected() public view {
        bytes32[] memory pi = _piWallet(3, 1, 2020, address(0xB0B));
        bytes32 wrongInner = keccak256(abi.encode(keccak256("WRONG:DOMAIN"), pi[0], pi[1], pi[2], pi[3], pi[4]));
        bytes32 wrongDigest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", wrongInner));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(oraclePk, wrongDigest);
        assertFalse(verifier.verify(abi.encodePacked(r, s, v), pi), "wrong domain must fail");
    }

    function test_yearChange_invalidatesOldSig() public view {
        bytes32[] memory pi = _piWallet(3, 1, 2020, address(0xB0B));
        bytes memory sig = _sig(oraclePk, pi);
        pi[2] = bytes32(uint256(2099)); // change year after signing
        assertFalse(verifier.verify(sig, pi));
    }

    // ── H. Multi-oracle isolation ────────────────────────────────────────────

    function test_signatureForOtherOracleRejected() public {
        OracleAttestationVerifier verifierB = new OracleAttestationVerifier(vm.addr(otherPk));
        bytes32[] memory pi = _piWallet(3, 1, 2020, address(0xB0B));
        // oracle A's signature is valid on A, rejected on B
        bytes memory sigA = _sig(oraclePk, pi);
        assertTrue(verifier.verify(sigA, pi));
        assertFalse(verifierB.verify(sigA, pi));
    }

    // ── I. Registry integration corners ──────────────────────────────────────

    function test_registry_doubleRegisterReverts() public {
        GrantIdentityRegistry reg = new GrantIdentityRegistry(address(verifier));
        address w = address(0xB0B);
        bytes32[] memory pi = _piWallet(3, 100, 2020, w);
        bytes memory sig = _sig(oraclePk, pi);

        vm.prank(w);
        reg.verifyIdentity(sig, pi, "octocat");

        vm.prank(w);
        vm.expectRevert("Already verified");
        reg.verifyIdentity(sig, pi, "octocat");
    }

    function test_registry_githubIdUniqueness() public {
        GrantIdentityRegistry reg = new GrantIdentityRegistry(address(verifier));
        address w1 = address(0xB0B);
        address w2 = address(0xCAFE);

        bytes32[] memory p1 = _piWallet(3, 555, 2020, w1);
        bytes memory s1 = _sig(oraclePk, p1);
        vm.prank(w1);
        reg.verifyIdentity(s1, p1, "octocat");

        // a second wallet with a valid oracle attestation for the SAME githubId
        bytes32[] memory p2 = _piWallet(2, 555, 2020, w2);
        bytes memory s2 = _sig(oraclePk, p2);
        vm.prank(w2);
        vm.expectRevert("GitHub ID already registered");
        reg.verifyIdentity(s2, p2, "octocat2");
    }

    function test_registry_wrongSenderBindingReverts() public {
        GrantIdentityRegistry reg = new GrantIdentityRegistry(address(verifier));
        // oracle attests for builder, but a different wallet submits it
        bytes32[] memory pi = _piWallet(3, 1, 2020, address(0xB0B));
        bytes memory sig = _sig(oraclePk, pi);

        vm.prank(address(0xBAD));
        vm.expectRevert("Proof not bound to sender");
        reg.verifyIdentity(sig, pi, "octocat");
    }

    function test_registry_emptyHandleReverts() public {
        GrantIdentityRegistry reg = new GrantIdentityRegistry(address(verifier));
        address w = address(0xB0B);
        bytes32[] memory pi = _piWallet(3, 1, 2020, w);
        bytes memory sig = _sig(oraclePk, pi);
        vm.prank(w);
        vm.expectRevert("Invalid handle");
        reg.verifyIdentity(sig, pi, "");
    }

    // ── J. Fuzz boundaries ───────────────────────────────────────────────────

    function testFuzz_anyNon65LengthRejected(uint16 len) public view {
        vm.assume(len != 65 && len <= 4096);
        bytes memory proof = new bytes(len);
        for (uint256 i; i < proof.length; i++) {
            proof[i] = 0x01;
        }
        assertFalse(verifier.verify(proof, _piWallet(1, 1, 2020, address(1))));
    }

    function testFuzz_anyInvalidVRejected(uint8 v) public view {
        vm.assume(v != 27 && v != 28 && v != 0 && v != 1);
        bytes32[] memory pi = _piWallet(2, 7, 2019, address(0xB0B));
        (bytes32 r, bytes32 s,) = _rsv(oraclePk, pi);
        assertFalse(verifier.verify(abi.encodePacked(r, s, v), pi));
    }

    function testFuzz_singleFieldMutationBreaksSig(uint8 idx, bytes32 val) public view {
        idx = uint8(bound(idx, 0, 4));
        bytes32[] memory pi = _piWallet(3, 85998029, 2021, address(0xB0B));
        bytes memory sig = _sig(oraclePk, pi);
        vm.assume(val != pi[idx]);
        pi[idx] = val; // mutate any one signed field
        assertFalse(verifier.verify(sig, pi), "mutating any signed field must break the sig");
    }
}
