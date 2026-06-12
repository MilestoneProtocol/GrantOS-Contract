// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/OracleAttestationVerifier.sol";
import "../src/GrantIdentityRegistry.sol";

/// @notice "Ultra" end-to-end demonstration that the OracleAttestationVerifier
///         actually works: one legitimate attestation is ACCEPTED, and a full
///         battery of forgery / tamper / replay / malleability attacks are all
///         REJECTED. Run with:  forge test --match-contract UltraVerifierDemo -vvv
contract UltraVerifierDemoTest is Test {
    OracleAttestationVerifier verifier;

    uint256 oraclePk = uint256(keccak256("grantos.oracle.key"));
    address oracle;
    uint256 attackerPk = uint256(keccak256("attacker.key"));

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
        pi[3] = bytes32(0);
        pi[4] = bytes32(uint256(uint160(wallet)));
    }

    function _sign(uint256 pk, bytes32[] memory pi) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, verifier.attestationHash(pi));
        return abi.encodePacked(r, s, v);
    }

    function _line() internal pure {
        console.log("------------------------------------------------------------");
    }

    function test_ultra_demo() public view {
        address builder = address(0xB0B);

        _line();
        console.log("GrantOS OracleAttestationVerifier - ULTRA DEMO");
        _line();
        console.log("Trusted oracle signer :", oracle);
        console.log("Attacker signer       :", vm.addr(attackerPk));
        _line();

        // 1) Legitimate oracle attestation -> ACCEPTED
        console.log("[1] Oracle attests: builder=0xB0B, tier=3, githubId=85998029, year=2021");
        bytes32[] memory pi = _inputs(3, 85998029, 2021, builder);
        console.log("    attestationHash :");
        console.logBytes32(verifier.attestationHash(pi));
        bytes memory sig = _sign(oraclePk, pi);
        console.log("    oracle signature (65 bytes):");
        console.logBytes(sig);
        bool ok = verifier.verify(sig, pi);
        console.log("    verify() ->", ok ? "ACCEPTED (correct)" : "rejected (BUG)");
        assertTrue(ok);
        _line();

        // 2) Attacker forges a tier-3 identity bound to their own wallet, self-signs
        console.log("[2] ATTACK: attacker self-signs a tier-3 attestation for themselves");
        bytes32[] memory f = _inputs(3, 85998029, 2021, vm.addr(attackerPk));
        bool forged = verifier.verify(_sign(attackerPk, f), f);
        console.log("    verify() ->", forged ? "ACCEPTED (BUG!)" : "REJECTED (correct)");
        assertFalse(forged);
        _line();

        // 3) Tamper: upgrade tier 1 -> 3 after a legit signature over tier 1
        console.log("[3] ATTACK: take a legit tier-1 sig, then bump tier to 3");
        bytes32[] memory t = _inputs(1, 85998029, 2021, builder);
        bytes memory tSig = _sign(oraclePk, t);
        t[0] = bytes32(uint256(3));
        bool tampered = verifier.verify(tSig, t);
        console.log("    verify() ->", tampered ? "ACCEPTED (BUG!)" : "REJECTED (correct)");
        assertFalse(tampered);
        _line();

        // 4) Replay: take the builder's real signature, rebind it to attacker wallet
        console.log("[4] ATTACK: replay builder's real sig, swap wallet to attacker");
        bytes32[] memory r = _inputs(3, 85998029, 2021, builder);
        bytes memory rSig = _sign(oraclePk, r);
        r[4] = bytes32(uint256(uint160(vm.addr(attackerPk))));
        bool replayed = verifier.verify(rSig, r);
        console.log("    verify() ->", replayed ? "ACCEPTED (BUG!)" : "REJECTED (correct)");
        assertFalse(replayed);
        _line();

        // 5) The exact exploit the OLD no-op accepted: a 2KB non-zero blob
        console.log("[5] ATTACK: random 2KB blob (the OLD return-true verifier accepted this)");
        bytes memory blob = new bytes(2048);
        blob[0] = 0x01;
        bool blobOk = verifier.verify(blob, pi);
        console.log("    verify() ->", blobOk ? "ACCEPTED (BUG!)" : "REJECTED (correct)");
        assertFalse(blobOk);
        _line();

        // 6) Signature malleability: high-s variant of a valid signature
        console.log("[6] ATTACK: malleable high-s variant of a valid oracle signature");
        (uint8 v, bytes32 sr, bytes32 ss) = vm.sign(oraclePk, verifier.attestationHash(pi));
        bytes memory mal = abi.encodePacked(sr, bytes32(N - uint256(ss)), v == 27 ? uint8(28) : uint8(27));
        bool malOk = verifier.verify(mal, pi);
        console.log("    verify() ->", malOk ? "ACCEPTED (BUG!)" : "REJECTED (correct)");
        assertFalse(malOk);
        _line();

        console.log("RESULT: 1 legitimate attestation ACCEPTED, 5 attacks REJECTED.");
        _line();
    }

    /// Full identity flow through the real registry, with logs.
    function test_ultra_registryFlow() public {
        GrantIdentityRegistry registry = new GrantIdentityRegistry(address(verifier));
        address builder = address(0xB0B);

        _line();
        console.log("ULTRA DEMO - GrantIdentityRegistry end-to-end");
        _line();

        // Legit registration (sign BEFORE prank so prank applies to verifyIdentity)
        bytes32[] memory pi = _inputs(3, 85998029, 2021, builder);
        bytes memory okSig = _sign(oraclePk, pi);
        vm.prank(builder);
        registry.verifyIdentity(okSig, pi, "octocat");
        console.log(
            "[A] builder registered via oracle attestation ->", registry.isVerified(builder) ? "VERIFIED" : "FAILED"
        );
        console.log("    on-chain tier :", registry.getIdentity(builder).tier);
        assertTrue(registry.isVerified(builder));
        assertEq(registry.getIdentity(builder).tier, 3);
        _line();

        // Forged registration must revert
        address imposter = address(0xBAD);
        bytes32[] memory f = _inputs(3, 85998029, 2021, imposter);
        bytes memory badSig = _sign(attackerPk, f);
        vm.prank(imposter);
        vm.expectRevert("Invalid ZK proof");
        registry.verifyIdentity(badSig, f, "imposter");
        console.log("[B] imposter self-signed tier-3 -> reverted 'Invalid ZK proof' (correct)");
        console.log("    imposter verified? ->", registry.isVerified(imposter) ? "YES (BUG)" : "NO (correct)");
        assertFalse(registry.isVerified(imposter));
        _line();
    }

    /// Ultra fuzz: across many random keys, ONLY the oracle key is ever accepted.
    function testFuzz_ultra_noKeyButOracleForges(uint256 pk, uint256 tier, uint256 gid, address w) public view {
        pk = bound(pk, 1, N - 1);
        tier = bound(tier, 0, 3);
        bytes32[] memory pi = _inputs(tier, gid, 2020, w);
        assertEq(verifier.verify(_sign(pk, pi), pi), vm.addr(pk) == oracle);
    }
}
