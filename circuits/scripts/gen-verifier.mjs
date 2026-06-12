// Generate the REAL on-chain UltraHonk Solidity verifier for the Schnorr-based
// grant identity circuit, using @aztec/bb.js (the version paired with the nargo
// that compiled the circuit). The legacy secp256k1 circuit could not produce a
// Solidity verifier; this one can because it stays in the native BN254/Grumpkin
// field. Uses the keccak transcript so the verifier is EVM-friendly.
import { Barretenberg, UltraHonkBackend } from '@aztec/bb.js';
import { readFileSync, writeFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const here = dirname(fileURLToPath(import.meta.url));
const circuitPath = join(here, '..', 'target', 'grant_identity_proof.json');
const outPath = join(here, '..', 'target', 'Verifier.sol');

const circuit = JSON.parse(readFileSync(circuitPath, 'utf8'));
console.log('[gen-verifier] circuit loaded:', circuitPath);

const api = await Barretenberg.new({ threads: 1 });
const backend = new UltraHonkBackend(circuit.bytecode, api);

console.log('[gen-verifier] computing verification key (keccak transcript)...');
const vk = await backend.getVerificationKey({ keccak: true });
console.log('[gen-verifier] VK bytes:', vk.length);

console.log('[gen-verifier] generating Solidity verifier...');
const sol = await backend.getSolidityVerifier(vk, { keccak: true });
writeFileSync(outPath, sol);
console.log('[gen-verifier] wrote', outPath, '(', sol.length, 'chars )');

await backend.destroy?.();
await api.destroy?.();
process.exit(0);
