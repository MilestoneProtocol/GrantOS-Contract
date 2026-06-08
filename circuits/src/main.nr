use std::ecdsa_secp256k1;

// GrantOS ZK Coprocessor v2
//
// Public outputs: (tier, github_id, github_created_year, wallet_address_hi, wallet_address_lo)
//
// Payload signed by oracle (SHA-256 of ABI-encoded):
//   (wallet_address: address, github_id: uint256, github_created_year: uint256,
//    commits: uint32, stars: uint32, events: uint32)

fn main(
    // Private inputs
    signature:    [u8; 64],
    message_hash: [u8; 32],
    commits:      u32,
    stars:        u32,
    events:       u32,

    // Public inputs
    github_id:           Field,
    github_created_year: Field,
    wallet_address_hi:   Field,
    wallet_address_lo:   Field,
) -> pub (Field, Field, Field, Field, Field) {

    // Hardcoded oracle public key (derived from ORACLE_PRIVATE_KEY v2)
    let oracle_pub_key_x: [u8; 32] = [110, 7, 53, 10, 88, 38, 90, 166, 213, 99, 10, 179, 68, 179, 107, 109, 138, 180, 16, 29, 82, 102, 229, 134, 181, 248, 137, 250, 184, 119, 48, 88];
    let oracle_pub_key_y: [u8; 32] = [13, 56, 187, 15, 188, 160, 220, 154, 229, 207, 122, 15, 178, 84, 33, 38, 184, 100, 170, 22, 26, 122, 191, 112, 141, 111, 120, 31, 122, 98, 17, 234];

    // Step 1: verify oracle ECDSA signature
    let is_valid = ecdsa_secp256k1::verify_signature(
        oracle_pub_key_x,
        oracle_pub_key_y,
        signature,
        message_hash,
    );
    assert(is_valid, "Oracle signature verification failed");

    // Step 2: range-check public inputs
    let id_u64: u64 = github_id as u64;
    assert(github_id == id_u64 as Field, "github_id exceeds u64 range");

    let year_u32: u32 = github_created_year as u32;
    assert(github_created_year == year_u32 as Field, "github_created_year out of Field range");
    assert(year_u32 >= 2008, "github_created_year predates GitHub (2008)");
    assert(year_u32 <= 2100, "github_created_year too far in future");

    let hi_u128: u128 = wallet_address_hi as u128;
    let lo_u128: u128 = wallet_address_lo as u128;
    assert(wallet_address_hi == hi_u128 as Field, "wallet_address_hi overflows 128 bits");
    assert(wallet_address_lo == lo_u128 as Field, "wallet_address_lo overflows 128 bits");
    assert(hi_u128 < 0x100000000, "wallet_address_hi exceeds 32 bits");

    // Step 3: compute contribution tier
    // 0 = Member  1 = Bronze  2 = Silver  3 = Gold
    let mut tier: Field = 0;

    if (commits > 500) | (stars > 100) | (events > 100) {
        tier = 3;
    } else if (commits > 100) | (stars > 20) | (events > 30) {
        tier = 2;
    } else if (commits > 10) | (stars > 5) | (events > 5) {
        tier = 1;
    }

    // Step 4: return public outputs
    (tier, github_id, github_created_year, wallet_address_hi, wallet_address_lo)
}
