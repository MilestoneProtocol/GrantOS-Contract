// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract ShiftTest {
    function testShift() public pure returns (bool, uint160, uint160, uint160) {
        bytes32 hiBytes = 0x00000000000000000000000000000000000000000000000000000000a4bd74f9;
        bytes32 loBytes = 0x000000000000000000000000000000009b2b7e2b7f762774237da17e0970921b;
        
        uint160 addressHi = uint160(uint256(hiBytes)) << 128;
        uint160 addressLo = uint160(uint256(loBytes));
        
        uint160 combined = addressHi | addressLo;
        address grantee = 0xa4bd74F99b2b7e2b7f762774237Da17E0970921B;
        
        return (combined == uint160(grantee), addressHi, addressLo, combined);
    }
}
