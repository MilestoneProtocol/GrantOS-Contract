// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IWebProofVerifier.sol";

/// @title StubWebProofVerifier
/// @notice HACKATHON DEMO ONLY — accepts any Web Proof.
///         Replace with the real Noir ZK Coprocessor verifier generated contract
///         before going to production.
contract StubWebProofVerifier is IWebProofVerifier {
    function verify(
        bytes calldata /* proof */,
        bytes32[] calldata /* publicInputs */
    ) external pure override returns (bool) {
        return true;
    }
}
