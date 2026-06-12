// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/OracleAttestationVerifier.sol";
import "../src/GrantIdentityRegistry.sol";
import "../src/GrantEscrow.sol";
import "../src/GrantFactory.sol";
import "../src/SentinelEAS.sol";

// Minimal mocks so the full system can be deployed & exercised on a local node.
contract LocalUSDC {
    string public name = "Mock USDC";
    string public symbol = "USDC";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address t, uint256 a) external returns (bool) {
        require(balanceOf[msg.sender] >= a, "bal");
        balanceOf[msg.sender] -= a;
        balanceOf[t] += a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        require(balanceOf[f] >= a && allowance[f][msg.sender] >= a, "bal/allow");
        balanceOf[f] -= a;
        balanceOf[t] += a;
        allowance[f][msg.sender] -= a;
        return true;
    }
}

contract LocalEAS {
    function attest(IEAS.AttestationRequest calldata r) external returns (bytes32) {
        return keccak256(abi.encodePacked(block.timestamp, msg.sender, r.data.recipient));
    }

    function getAttestation(bytes32) external pure returns (IEAS.Attestation memory a) {
        return a;
    }
}

contract LocalSablier {
    uint256 public nextId = 1;

    function createWithDurations(ISablierV2LockupLinear.CreateWithDurations calldata p) external returns (uint256) {
        require(IERC20(p.asset).transferFrom(msg.sender, address(this), p.totalAmount), "pull");
        return nextId++;
    }
    function cancel(uint256) external {}
}

/// @notice Full local deployment of the GrantOS v3 system (post-audit-fix).
/// Env:
///   DEPLOYER_PRIVATE_KEY  — deployer key (anvil acct 0)
///   ORACLE_ADDRESS        — trusted oracle signer (must match backend ORACLE_PRIVATE_KEY)
contract DeployLocal is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address oracle = vm.envAddress("ORACLE_ADDRESS");

        vm.startBroadcast(deployerKey);

        LocalUSDC usdc = new LocalUSDC();
        LocalEAS eas = new LocalEAS();
        LocalSablier sablier = new LocalSablier();

        OracleAttestationVerifier verifier = new OracleAttestationVerifier(oracle);
        GrantIdentityRegistry registry = new GrantIdentityRegistry(address(verifier));
        SentinelEAS sentinel = new SentinelEAS(address(eas), bytes32(0));
        sentinel.setAuthorizedIssuer(oracle, true); // backend oracle may issue warnings

        GrantEscrow impl = new GrantEscrow();
        GrantFactory factory = new GrantFactory(
            address(impl), address(usdc), address(registry), address(sentinel), address(sablier), address(verifier)
        );

        vm.stopBroadcast();

        console.log("=== GrantOS local deployment (chainId %s) ===", block.chainid);
        console.log("ORACLE_SIGNER          ", oracle);
        console.log("MockUSDC               ", address(usdc));
        console.log("MockEAS                ", address(eas));
        console.log("MockSablier            ", address(sablier));
        console.log("OracleAttestationVerifier", address(verifier));
        console.log("GrantIdentityRegistry  ", address(registry));
        console.log("SentinelEAS            ", address(sentinel));
        console.log("GrantEscrow (impl)     ", address(impl));
        console.log("GrantFactory           ", address(factory));
    }
}
