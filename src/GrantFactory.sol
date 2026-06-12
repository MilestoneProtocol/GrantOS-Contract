// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./GrantEscrow.sol";

contract GrantFactory {
    address public implementation;
    address public usdc;
    address public registry;
    address public sentinel;
    address public sablier;
    address public verifier;

    uint256 public grantCount;
    mapping(uint256 => address) public grants; // grantId => escrow address

    event GrantCreated(
        uint256 indexed grantId,
        address indexed escrow,
        address indexed grantor,
        address grantee,
        uint256 totalAmount
    );

    constructor(
        address _implementation,
        address _usdc,
        address _registry,
        address _sentinel,
        address _sablier,
        address _verifier
    ) {
        implementation = _implementation;
        usdc = _usdc;
        registry = _registry;
        sentinel = _sentinel;
        sablier = _sablier;
        verifier = _verifier;
    }

    // EIP-1167 minimal proxy clone
    function _clone(address target) internal returns (address result) {
        bytes20 targetBytes = bytes20(target);
        assembly {
            let cloneBuffer := mload(0x40)
            mstore(cloneBuffer, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(cloneBuffer, 0x14), targetBytes)
            mstore(add(cloneBuffer, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            result := create(0, cloneBuffer, 0x37)
        }
    }

    /**
     * @notice Create a new grant escrow.
     * @param grantee       Builder wallet address
     * @param streaming     true = Superfluid streaming, false = lump-sum
     * @param committee     2–7 reviewer wallet addresses
     * @param quorum        Minimum approvals required
     * @param milestones    1–10 milestone structs
     *
     * Caller must have approved this contract to spend totalAmount USDC before calling.
     */
    function createGrant(
        address grantee,
        bool streaming,
        address[] calldata committee,
        uint256 quorum,
        GrantEscrow.MilestoneInput[] calldata milestones
    ) external returns (uint256 grantId, address escrowAddr) {
        escrowAddr = _clone(implementation);
        GrantEscrow escrow = GrantEscrow(escrowAddr);

        grantId = grantCount++;
        bytes32 grantIdBytes = bytes32(grantId);

        escrow.initialize(
            usdc,
            registry,
            sentinel,
            sablier,
            verifier,
            msg.sender,
            grantee,
            streaming,
            committee,
            quorum,
            milestones,
            grantIdBytes
        );

        // Transfer total USDC into the escrow in one shot
        uint256 totalAmount = 0;
        for (uint i = 0; i < milestones.length; i++) {
            totalAmount += milestones[i].amount;
        }
        require(
            IERC20(usdc).transferFrom(msg.sender, escrowAddr, totalAmount),
            "USDC transfer failed"
        );

        grants[grantId] = escrowAddr;

        emit GrantCreated(grantId, escrowAddr, msg.sender, grantee, totalAmount);
    }
}
