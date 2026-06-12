use schnorr::verify_signature;
use std::embedded_curve_ops::{EmbeddedCurvePoint, EmbeddedCurveScalar};
use poseidon::poseidon2::Poseidon2;

// GrantOS ZK Coprocessor v3 -- Schnorr over Grumpkin with a Poseidon2 challenge.
//
// The trusted oracle signs a Poseidon2 commitment to the GitHub payload with a
// Schnorr signature over the Grumpkin embedded curve. Verifying that signature
// in-circuit (instead of secp256k1 ECDSA) keeps the whole circuit inside the
// native BN254/Grumpkin field, so Barretenberg can generate a REAL on-chain
// UltraHonk Solidity verifier (the secp256k1 path could not).
//
// Public outputs (the verifier's public inputs, in order):
//   (tier, github_id, github_created_year, wallet_address_hi, wallet_address_lo)

global TWO_POW_128: Field = 0x100000000000000000000000000000000;

// Hardcoded oracle Grumpkin public key, generated 2026-06-10 by
// GrantOS-Backend/scripts/oracle-keygen.mjs. The matching private key lives in
// the backend env as ORACLE_SCHNORR_PRIVATE_KEY. Rotating the key requires
// recompiling this circuit and redeploying the on-chain verifier.
global ORACLE_PUB_X: Field = 0x008a426d4aa214e4c7c5d66e9a37f3cfa5dd384ca3377723b2661e40ae6f6e4e;
global ORACLE_PUB_Y: Field = 0x223e537e188e8c5410cce469df962bac525c0fd2e158563a4eacb0c8e598490c;

fn main(
    // -- Private witness --
    sig_s_lo: Field,
    sig_s_hi: Field,
    sig_e_lo: Field,
    sig_e_hi: Field,
    commits: u32,
    stars: u32,
    events: u32,
    github_id: Field,
    github_created_year: Field,
    wallet_address_hi: Field,
    wallet_address_lo: Field,
) -> pub (Field, Field, Field, Field, Field) {
    // -- Step 1: reconstruct the signed message --
    // Bind wallet + identity attributes + raw metrics into one Poseidon2 digest.
    let wallet: Field = wallet_address_hi * TWO_POW_128 + wallet_address_lo;
    let message: Field = Poseidon2::hash(
        [
            wallet,
            github_id,
            github_created_year,
            commits as Field,
            stars as Field,
            events as Field,
        ],
        6,
    );

    // -- Step 2: verify the oracle's Schnorr signature --
    let pk = EmbeddedCurvePoint::new(ORACLE_PUB_X, ORACLE_PUB_Y);
    let s = EmbeddedCurveScalar::new(sig_s_lo, sig_s_hi);
    let e = EmbeddedCurveScalar::new(sig_e_lo, sig_e_hi);
    assert(verify_signature(pk, (s, e), message), "Oracle signature verification failed");

    // -- Step 3: range-check public inputs --
    let year_u32: u32 = github_created_year as u32;
    assert(github_created_year == year_u32 as Field, "github_created_year out of u32 range");
    assert(year_u32 >= 2008, "github_created_year predates GitHub (2008)");
    assert(year_u32 <= 2100, "github_created_year too far in future");

    // wallet_address_hi must fit in 32 bits (upper 4 bytes of the address)
    let hi_u64: u64 = wallet_address_hi as u64;
    assert(wallet_address_hi == hi_u64 as Field, "wallet_address_hi overflows 64 bits");
    assert(hi_u64 < 0x100000000, "wallet_address_hi exceeds 32 bits");

    // -- Step 4: contribution tier (0 = Member, 1 = Bronze, 2 = Silver, 3 = Gold) --
    let mut tier: Field = 0;
    if (commits > 500) | (stars > 100) | (events > 100) {
        tier = 3;
    } else if (commits > 100) | (stars > 20) | (events > 30) {
        tier = 2;
    } else if (commits > 10) | (stars > 5) | (events > 5) {
        tier = 1;
    }

    (tier, github_id, github_created_year, wallet_address_hi, wallet_address_lo)
}
