// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IWebProofVerifier
/// @notice Interface for verifying Noir ZK Coprocessor proofs on-chain.
///         Deployed alongside each GrantEscrow for milestone-level ZK proof verification.
interface IWebProofVerifier {
    /// @notice Verify a ZK proof against the given public inputs.
    /// @param proof        The serialized ZK proof bytes
    /// @param publicInputs The public inputs to verify against
    /// @return True if the proof is valid, false otherwise
    function verify(bytes calldata proof, bytes32[] calldata publicInputs) external view returns (bool);
}
