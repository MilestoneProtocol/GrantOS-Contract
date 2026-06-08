// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/INoirVerifier.sol";

contract GrantIdentityRegistry {
    INoirVerifier public verifier;

    struct Identity {
        bool isVerified;
        uint256 tier;
        uint256 githubId;
        uint256 createdYear;
        string  githubHandle;
    }

    mapping(address => Identity) public identities;
    mapping(uint256 => address) public githubIdToAddress;

    event IdentityVerified(address indexed wallet, uint256 tier, uint256 githubId, uint256 createdYear, string githubHandle);

    constructor(address _verifier) {
        verifier = INoirVerifier(_verifier);
    }

    function verifyIdentity(
        bytes calldata proof,
        bytes32[] calldata publicInputs,
        string calldata githubHandle
    ) external {
        require(!identities[msg.sender].isVerified, "Already verified");
        require(bytes(githubHandle).length > 0 && bytes(githubHandle).length <= 39, "Invalid handle");

        // publicInputs format from main.nr:
        // [0] tier
        // [1] github_id
        // [2] github_created_year
        // [3] wallet_address_hi (upper 4 bytes)
        // [4] wallet_address_lo (lower 16 bytes)

        uint160 addressHi = uint160(uint256(publicInputs[3])) << 128;
        uint160 addressLo = uint160(uint256(publicInputs[4]));
        require((addressHi | addressLo) == uint160(msg.sender), "Proof not bound to sender");

        require(verifier.verify(proof, publicInputs), "Invalid ZK proof");

        uint256 tier        = uint256(publicInputs[0]);
        uint256 githubId    = uint256(publicInputs[1]);
        uint256 createdYear = uint256(publicInputs[2]);

        require(githubIdToAddress[githubId] == address(0), "GitHub ID already registered");

        identities[msg.sender] = Identity({
            isVerified:   true,
            tier:         tier,
            githubId:     githubId,
            createdYear:  createdYear,
            githubHandle: githubHandle
        });
        githubIdToAddress[githubId] = msg.sender;

        emit IdentityVerified(msg.sender, tier, githubId, createdYear, githubHandle);
    }

    function isVerified(address wallet) external view returns (bool) {
        return identities[wallet].isVerified;
    }

    function getIdentity(address wallet) external view returns (Identity memory) {
        return identities[wallet];
    }
}
