#!/usr/bin/env node
/**
 * Generate UltraHonk Solidity verifier using @aztec/bb.js
 * This is the BEST solution - uses the same library as the frontend prover
 */

const fs = require('fs');
const path = require('path');

async function generateVerifier() {
  console.log('🔧 Generating UltraHonk Solidity verifier...\n');

  // Import bb.js dynamically (ESM module)
  const { Barretenberg, BackendType, UltraHonkBackend } = await import('@aztec/bb.js');

  // Load circuit artifact
  const circuitPath = path.join(__dirname, '../circuits/target/grant_identity_proof.json');
  console.log(`📂 Loading circuit from: ${circuitPath}`);
  
  if (!fs.existsSync(circuitPath)) {
    console.error('❌ Circuit artifact not found!');
    console.error('   Run: cd circuits && nargo compile');
    process.exit(1);
  }

  const circuit = JSON.parse(fs.readFileSync(circuitPath, 'utf8'));
  console.log('✅ Circuit loaded\n');

  // Initialize Barretenberg
  console.log('⚙️  Initializing Barretenberg...');
  const api = await Barretenberg.new({ threads: 1, backend: BackendType.Wasm });
  console.log('✅ Barretenberg initialized\n');

  // Create backend
  console.log('🔨 Creating UltraHonk backend...');
  const backend = new UltraHonkBackend(circuit.bytecode, api);
  console.log('✅ Backend created\n');

  // Generate verifier contract
  console.log('📝 Generating Solidity verifier contract...');
  console.log('   (This may take 30-60 seconds...)\n');
  
  const verifierContract = await backend.generateSolidityContract();
  
  // Write to file
  const outputPath = path.join(__dirname, '../src/UltraHonkVerifier.sol');
  fs.writeFileSync(outputPath, verifierContract);
  
  const sizeKB = (verifierContract.length / 1024).toFixed(2);
  console.log(`✅ Verifier contract generated!`);
  console.log(`   📄 File: ${outputPath}`);
  console.log(`   📊 Size: ${sizeKB} KB`);
  console.log(`   ⛽ Estimated deployment gas: ~${Math.ceil(verifierContract.length / 200)}K gas\n`);
  
  console.log('🎉 SUCCESS! Next steps:');
  console.log('   1. Review the generated contract');
  console.log('   2. Update DeployEscrow.s.sol to deploy UltraHonkVerifier');
  console.log('   3. Update GrantFactory to use the new verifier address');
  console.log('   4. Deploy to testnet and verify\n');
}

generateVerifier().catch(err => {
  console.error('❌ Error generating verifier:', err);
  process.exit(1);
});
