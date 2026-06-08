#!/bin/bash
# Install Barretenberg CLI and generate verifier

set -e

echo "📦 Installing Barretenberg CLI (bb)..."
echo "⚠️  This will take 10-30 minutes and requires ~5GB disk space"
echo ""

# Install bb
curl -L https://raw.githubusercontent.com/AztecProtocol/aztec-packages/master/barretenberg/cpp/installation/install | bash

# Add to PATH for current session
export PATH="$HOME/.bb:$PATH"

# Verify installation
if ! command -v bb &> /dev/null; then
    echo "❌ Installation failed"
    exit 1
fi

echo "✅ bb installed successfully"
echo ""

# Generate verifier
cd "$(dirname "$0")/../circuits"

echo "🔧 Generating UltraHonk verifier contract..."
bb contract -b target/grant_identity_proof.json -o ../src/UltraHonkVerifier.sol

echo "✅ Verifier generated at src/UltraHonkVerifier.sol"
echo ""
echo "⚠️  IMPORTANT: The generated contract is ~50-100KB"
echo "   Gas cost for deployment: ~10-15M gas (~$50-100 on mainnet)"
echo ""
echo "Next: Update DeployEscrow.s.sol to deploy UltraHonkVerifier"
