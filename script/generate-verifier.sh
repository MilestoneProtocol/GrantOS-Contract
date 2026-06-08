#!/bin/bash
# Generate UltraHonk Solidity verifier from Noir circuit

set -e

echo "🔧 Generating UltraHonk verifier contract..."

cd "$(dirname "$0")/../circuits"

# Ensure circuit is compiled
if [ ! -f "target/grant_identity_proof.json" ]; then
    echo "❌ Circuit not compiled. Run 'nargo compile' first."
    exit 1
fi

# Generate verifier contract using bb
# Note: Requires bb (Barretenberg CLI) to be installed
# Install: curl -L https://raw.githubusercontent.com/AztecProtocol/aztec-packages/master/barretenberg/cpp/installation/install | bash

if ! command -v bb &> /dev/null; then
    echo "❌ bb (Barretenberg CLI) not found."
    echo "Install with: curl -L https://raw.githubusercontent.com/AztecProtocol/aztec-packages/master/barretenberg/cpp/installation/install | bash"
    exit 1
fi

echo "📝 Generating Solidity verifier..."
bb contract -b target/grant_identity_proof.json -o ../src/UltraHonkVerifier.sol

echo "✅ Verifier generated at src/UltraHonkVerifier.sol"
echo ""
echo "Next steps:"
echo "1. Review the generated contract"
echo "2. Update GrantFactory to use UltraHonkVerifier instead of StubNoirVerifier"
echo "3. Deploy to testnet and verify"
