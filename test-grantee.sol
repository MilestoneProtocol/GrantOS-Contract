// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract TestGrantee {
    function check(bytes32[] calldata publicInputs, address grantee) public pure returns (bool, uint160, uint160, uint160, uint160) {
        uint160 addressHi = uint160(uint256(publicInputs[3])) << 128;
        uint160 addressLo = uint160(uint256(publicInputs[4]));
        
        uint160 computed = addressHi | addressLo;
        uint160 expected = uint160(grantee);
        
        return (computed == expected, addressHi, addressLo, computed, expected);
    }
}
