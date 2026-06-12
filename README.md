# GrantOS — Milestone Protocol Contracts

> On-chain, milestone-based grant funding with cryptographic accountability.
> Grantors escrow USDC, builders prove their work, a committee votes, and money
> only moves when a milestone is genuinely delivered.

GrantOS replaces the trust-me-bro grant lifecycle (sign a doc, wire a lump sum,
hope for the best) with a verifiable on-chain flow. Funds sit in a per-grant
escrow. Each milestone is released only after a builder submits proof and a
reviewer committee reaches quorum. Builders who go dark on an overdue milestone
can be slashed — but only after a time-locked, attested warning, so slashing can
never be weaponized against someone who delivered on time.

---

## Why it exists

Traditional grant programs have three failure modes GrantOS closes:

| Problem | GrantOS answer |
| --- | --- |
| Money leaves before work is verified | USDC is escrowed per-grant and released milestone-by-milestone on committee quorum |
| Identity / contribution claims are unverifiable | **Zero-knowledge GitHub identity** — prove your contribution tier without doxxing your private data |
| Disputes are off-chain and arbitrary | Slashing is gated by **time-locked, attested warnings** (EAS) and a hard overdue check |

---

## Architecture

Five contracts plus a Noir ZK circuit, wired together by a factory.

```
                       ┌─────────────────────┐
                       │    GrantFactory     │  EIP-1167 minimal-proxy clones
                       │  createGrant(...)   │  one cheap escrow per grant
                       └──────────┬──────────┘
                                  │ clones + initializes
                                  ▼
        ┌──────────────────────────────────────────────────┐
        │                  GrantEscrow                       │
        │  • holds USDC          • committee voting + quorum │
        │  • milestone state     • lump-sum OR Sablier stream│
        │  • submit / approve / reject / slash / cancel      │
        └───┬───────────────┬───────────────┬───────────────┘
            │               │               │
            ▼               ▼               ▼
 ┌────────────────┐ ┌──────────────┐ ┌──────────────────────┐
 │ GrantIdentity  │ │  SentinelEAS │ │ OracleAttestation    │
 │   Registry     │ │  time-locked │ │   Verifier           │
 │ ZK GitHub IDs  │ │  warnings    │ │ INoirVerifier impl   │
 └───────┬────────┘ └──────────────┘ └──────────────────────┘
         │ verifies
         ▼
 ┌────────────────────────────────────────────────────────┐
 │  Noir circuit (circuits/src/main.nr)                    │
 │  Schnorr-over-Grumpkin sig + Poseidon2 commitment       │
 │  → compiles to a real on-chain UltraHonk verifier       │
 └────────────────────────────────────────────────────────┘
```

### Contracts

- **`GrantFactory`** — Deploys grants as [EIP-1167](https://eips.ethereum.org/EIPS/eip-1167)
  minimal-proxy clones of a single `GrantEscrow` implementation, so spinning up a
  new grant costs a fraction of a full deploy. Pulls the grantor's USDC and
  initializes the clone atomically.

- **`GrantEscrow`** — The heart of a single grant. Holds the USDC, stores the
  milestone schedule (1–10 milestones), and runs the full lifecycle:
  `submitMilestone → approveMilestone / rejectMilestone → payout / slash / cancel`.
  Supports a 2–7 member committee with a configurable quorum, two proof modes per
  milestone (ZK GitHub proof or EAS-evidence-only), and two payout rails:
  **lump-sum USDC** or **Sablier streaming** over 30 days. Reentrancy-guarded on
  every value-moving path.

- **`GrantIdentityRegistry`** — Maps a wallet to a verified GitHub identity and
  contribution tier. Verification consumes a ZK proof bound to `msg.sender`
  (the proof's public inputs encode the wallet address, so a proof can't be
  replayed by another account) and enforces one-GitHub-ID-per-wallet.

- **`SentinelEAS`** — Issues "this milestone is overdue" warnings as
  [EAS](https://attest.org) attestations. Warnings have a **24-hour maturity**
  and a **7-day expiry**: slashing is only allowed inside that window. An
  anti-reset guard stops anyone from refreshing a maturing warning to grief the
  builder, and only authorized issuers can plant warnings while only the original
  issuer or owner can deactivate one — so a grantee can't neutralize the warning
  gating their own slash.

- **`OracleAttestationVerifier`** — A drop-in `INoirVerifier` that verifies a
  trusted oracle's secp256k1 signature over the identity public inputs via native
  `ecrecover`, with a domain separator and EIP-2 low-`s` malleability rejection.
  It replaced an earlier no-op verifier that returned `true` unconditionally —
  the kind of bug that lets anyone forge a tier-3 identity.

### The ZK circuit

`circuits/src/main.nr` is a [Noir](https://noir-lang.org) circuit that proves a
builder's GitHub contribution tier **without revealing their raw metrics**. A
trusted oracle signs a Poseidon2 commitment to the GitHub payload with a
**Schnorr signature over the Grumpkin curve**. Verifying that signature inside
the circuit keeps everything in the native BN254/Grumpkin field, which is what
lets Barretenberg generate a *real* on-chain UltraHonk Solidity verifier — the
secp256k1 path could not. The circuit derives the tier (Member / Bronze / Silver
/ Gold) from commits, stars, and events, and range-checks every public input.

---

## Heavily tested

This is the part worth dwelling on. The protocol is **936 lines of Solidity
backed by ~3,200 lines of tests** — a >3:1 test-to-code ratio — and the suite
covers far more than the happy path.

```
132 tests, 13 suites, 0 failing.
Unit + fuzz + stateful invariant testing.
CI runs forge fmt --check, forge build --sizes, and forge test on every push.
```

### What the tests actually exercise

| Suite | Tests | Focus |
| --- | ---: | --- |
| `OracleVerifierEdgeCases.t.sol` | 31 | Malformed proofs, wrong signer, malleable `s`, boundary public inputs |
| `SentinelEAS.t.sol` | 19 | Warning maturity/expiry windows, anti-reset, authorization |
| `Voting.t.sol` | 17 | Quorum math, double-vote prevention, reject thresholds, resubmission |
| `OracleAttestationVerifier.t.sol` | 15 | ECDSA recovery, domain separation, EIP-2 low-`s` |
| `SlashMilestone.t.sol` | 12 | Slash state machine, overdue checks, on-time protection |
| `CancelGrant.t.sol` | 7 | Refund accounting, stream cancellation, no double-counting |
| `FeeOnTransferToken.t.sol` | 6 | Behavior under non-standard ERC-20s |
| `Reentrancy.t.sol` | 5 | Reentrancy guards on every value-moving path |
| `VerifierWiring.t.sol` / `SlashWarning.t.sol` | 4 + 4 | Verifier immutability, warning-gated slashing |
| `invariant/GrantInvariants.t.sol` | 8 | **Stateful fuzzing** (lump-sum + streaming) |
| `invariant/FactoryMultiGrant.t.sol` | 4 | Cross-grant isolation under random multi-grant sequences |

### Property-based invariant testing

Beyond example-based unit tests, the suite runs **stateful invariant fuzzing**
(`forge` config: 256 runs × 40-depth call sequences) that hammers the contracts
with randomized sequences of `createGrant / submit / approve / reject / cancel /
warnAndSlash / warp` and asserts these properties *never* break:

- **`invariant_conservation`** — no USDC is created or destroyed; escrow balance
  always equals funds in minus funds legitimately released.
- **`invariant_solvency`** — an escrow can always cover what it still owes.
- **`invariant_noOverpay`** — no milestone ever pays out more than its amount.
- **`invariant_voteBounds`** — vote counts never exceed committee size.
- **`invariant_globalConservation`** — value is conserved across *all* grants at once.
- **`invariant_perGrantIsolation`** — one grant's funds can never touch another's.
- **`invariant_factoryHoldsNothing`** — the factory never custodies user funds.
- **`invariant_grantCountMonotone`** — grant IDs only ever increase.

Across a full run that's **tens of thousands of randomized calls with zero
unexpected reverts and zero invariant violations.**

---

## Getting started

Built with [Foundry](https://book.getfoundry.sh/). The project uses `via_ir`
with the optimizer enabled (200 runs).

```shell
# Install dependencies (forge-std submodule)
forge install

# Build
forge build

# Run the full test suite
forge test

# Verbose, with traces
forge test -vvv

# Gas snapshot
forge snapshot

# Format
forge fmt
```

### Building the ZK verifier

The on-chain UltraHonk verifier is generated from the Noir circuit:

```shell
# Compiles circuits/src/main.nr and generates the Solidity verifier
bash script/install-bb-and-generate.sh
```

### Deployment

Deployment scripts live in `script/`:

```shell
# Deploy the full stack (registry, sentinel, escrow impl, factory)
forge script script/DeployAll.s.sol --rpc-url <RPC> --broadcast

# Or deploy components individually
forge script script/DeployRegistry.s.sol --rpc-url <RPC> --broadcast
forge script script/DeploySentinelAndFactory.s.sol --rpc-url <RPC> --broadcast
```

Copy `.env.example` to `.env` and fill in your RPC URL, deployer key, and the
USDC / EAS / Sablier addresses for your target chain before deploying.

---

## Repository layout

```
src/                       Solidity contracts
  GrantFactory.sol           EIP-1167 clone factory
  GrantEscrow.sol            per-grant escrow + milestone lifecycle
  GrantIdentityRegistry.sol  ZK GitHub identity registry
  SentinelEAS.sol            time-locked warning attestations
  OracleAttestationVerifier.sol  on-chain INoirVerifier (ecrecover)
  interfaces/                INoirVerifier, IWebProofVerifier
circuits/                  Noir ZK circuit + verifier generation
  src/main.nr                Schnorr/Grumpkin + Poseidon2 identity circuit
test/                      132 tests — unit, fuzz, edge cases
  invariant/                 stateful invariant fuzzing
script/                    Foundry deploy scripts + verifier tooling
```

---

## Milestone lifecycle at a glance

```
Pending ──submit──▶ Submitted ──quorum approvals──▶ Approved (paid)
   ▲                   │                                 or Streaming (Sablier)
   │                   └──reject threshold──▶ Pending (resubmit)
   │
   └── overdue + valid 24h warning ──▶ Slashed (funds returned to grantor)
```

A grantor can `cancelGrant` at any time to reclaim every unspent dollar;
already-approved and already-slashed milestones are left untouched and active
streams are cancelled so Sablier refunds the unstreamed remainder.

---

## License

MIT.
