use std::ecdsa_secp256k1;

// This is our ZK Coprocessor.
// It verifies that the GrantOS Backend (Trusted Oracle) signed a set of raw GitHub metrics,
// and it computes the "Contribution Tier" entirely inside Zero-Knowledge.
// The raw metrics (commits, stars) are NEVER exposed on-chain.

fn main(
    signature: [u8; 64], 
    message_hash: [u8; 32],
    github_id: Field,
    github_created_year: Field,
    commits: u32,
    stars: u32,
    events: u32
) -> pub (Field, Field, Field) {
    
    // Hardcoded Oracle Public Key (Derived from ORACLE_PRIVATE_KEY)
    let oracle_pub_key_x = [143, 79, 26, 59, 20, 21, 18, 146, 208, 214, 191, 61, 222, 108, 6, 12, 97, 37, 56, 230, 57, 225, 149, 27, 39, 233, 24, 215, 163, 1, 38, 13];
    let oracle_pub_key_y = [12, 3, 127, 189, 220, 183, 112, 22, 219, 105, 134, 217, 247, 66, 222, 205, 222, 93, 255, 255, 74, 43, 190, 44, 169, 73, 188, 167, 239, 14, 20, 132];

    // STEP 1: Verify the Oracle's ECDSA Signature
    let is_valid = ecdsa_secp256k1::verify_signature(
        oracle_pub_key_x, 
        oracle_pub_key_y, 
        signature, 
        message_hash
    );
    assert(is_valid);

    // STEP 2: Calculate the Contribution Tier inside ZK
    // 0 = Member, 1 = Bronze, 2 = Silver, 3 = Gold
    let mut tier = 0; 
    
    if (commits > 500) | (stars > 100) | (events > 100) {
        tier = 3; 
    } else if (commits > 100) | (stars > 20) | (events > 30) {
        tier = 2; 
    } else if (commits > 10) | (stars > 5) | (events > 5) {
        tier = 1; 
    }

    // Return the Tier, GitHub ID, and Account Creation Year.
    // Because we return them, they become `public` outputs of the ZK proof.
    // The Smart Contract will verify the proof and assign the badge to this exact GitHub ID.
    (tier, github_id, github_created_year)
}
