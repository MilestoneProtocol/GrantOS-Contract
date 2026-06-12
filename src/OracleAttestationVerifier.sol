// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/INoirVerifier.sol";

/// @title OracleAttestationVerifier
/// @notice Real on-chain verification of a trusted oracle's attestation over the
///         identity/tier public inputs, via native `ecrecover`.
///
///         This replaces the previous no-op `UltraHonkVerifier` (which performed
///         no cryptography and `return true`'d, letting anyone forge a tier-3
///         identity or squat any GitHub ID). The oracle already signs the GitHub
///         payload with a secp256k1 key; instead of proving that signature inside
///         a ZK circuit (which breaks Barretenberg's Solidity verifier
///         generation), we verify it directly on-chain.
///
///         Drop-in for `INoirVerifier`:
///           - `proof`        = the oracle's ECDSA signature, 65 bytes (r ‖ s ‖ v)
///           - `publicInputs` = [tier, githubId, githubYear, walletHi, walletLo]
///
///         Trust model: the oracle key is trusted to source GitHub data — the
///         same assumption the original design already made. This contract
///         *enforces* it on-chain rather than assuming it.
contract OracleAttestationVerifier is INoirVerifier {
    /// @notice The trusted oracle's signer address (set once at deployment).
    address public immutable oracle;

    /// @notice Domain separator binding signatures to this scheme/version.
    bytes32 public constant DOMAIN = keccak256("GrantOS:OracleAttestation:v1");

    /// @dev secp256k1 group order / 2, for EIP-2 low-`s` malleability rejection.
    uint256 private constant SECP256K1_N_HALF = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    error InvalidOracle();

    constructor(address _oracle) {
        if (_oracle == address(0)) revert InvalidOracle();
        oracle = _oracle;
    }

    /// @notice The EIP-191 personal-sign digest the oracle must sign for a given
    ///         set of public inputs. Exposed so off-chain signers and tests
    ///         derive the exact same hash.
    function attestationHash(bytes32[] calldata publicInputs) public pure returns (bytes32) {
        bytes32 inner = keccak256(
            abi.encode(DOMAIN, publicInputs[0], publicInputs[1], publicInputs[2], publicInputs[3], publicInputs[4])
        );
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", inner));
    }

    /// @inheritdoc INoirVerifier
    /// @dev Returns true iff `proof` is a valid secp256k1 signature by `oracle`
    ///      over the attestation digest of `publicInputs`. Returns false (never
    ///      reverts) on malformed input so callers keep their own revert reasons.
    function verify(bytes calldata proof, bytes32[] calldata publicInputs) external view override returns (bool) {
        if (publicInputs.length < 5) return false;
        if (proof.length != 65) return false;

        bytes32 r = bytes32(proof[0:32]);
        bytes32 s = bytes32(proof[32:64]);
        uint8 v = uint8(proof[64]);
        if (v < 27) v += 27; // normalize 0/1 recovery ids
        if (v != 27 && v != 28) return false;
        // Reject high-`s` (EIP-2) to forbid signature malleability.
        if (uint256(s) > SECP256K1_N_HALF) return false;

        address signer = ecrecover(attestationHash(publicInputs), v, r, s);
        return signer != address(0) && signer == oracle;
    }
}
