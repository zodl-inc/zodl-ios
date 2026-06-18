#include "stdint.h"

struct ExternError {
    int32_t code;
    char *message; // note: nullable
};

void keystone_sdk_destroy_string(const char* cstring);

// Sync
const char* parse_crypto_hd_key(struct ExternError*, const char* ur_type, const char* cbor_hex);
const char* parse_crypto_account(struct ExternError*, const char* ur_type, const char* cbor_hex);
const char* parse_crypto_multi_accounts(struct ExternError*, const char* ur_type, const char* cbor_hex);

// Utils
const char* get_uncompressed_key(struct ExternError*, const char* compressed_key);
const char* derive_public_key(struct ExternError*, const char* xpub, const char* path);
const char* parse_hd_path(struct ExternError*, const char* hd_path);

// BTC
const char* generate_crypto_psbt(struct ExternError*, const char* psbt_hex);
const char* parse_crypto_psbt(struct ExternError*, const char* ur_type, const char* cbor_hex);
const char* generate_btc_sign_request(struct ExternError*, const char* request_id, const char* sign_data, const int data_type, const char* accounts, const char* origin);
const char* parse_btc_signature(struct ExternError*, const char* ur_type, const char* cbor_hex);

// ETH
const char* generate_eth_sign_request(struct ExternError*, const char* request_id, const char* sign_data, const int data_type, const int chain_id, const char* path, const char* xfp, const char* address, const char* origin);
const char* parse_eth_signature(struct ExternError*, const char* ur_type, const char* cbor_hex);

// SOL
const char* generate_sol_sign_request(struct ExternError*, const char* request_id, const char* sign_data, const char* path, const char* xfp, const char* address, const char* origin, const int sign_type);
const char* parse_sol_signature(struct ExternError*, const char* ur_type, const char* cbor_hex);

// Cosmos
const char* generate_cosmos_sign_request(struct ExternError*, const char* request_id, const char* sign_data, const int data_type, const char* accounts, const char* origin);
const char* parse_cosmos_signature(struct ExternError*, const char* ur_type, const char* cbor_hex);

// Cosmos
const char* generate_evm_sign_request(struct ExternError*, const char* request_id, const char* sign_data, const int data_type, const int custom_chain_identifier, const char* account, const char* origin);
const char* parse_evm_signature(struct ExternError*, const char* ur_type, const char* cbor_hex);

// Tron
const char* generate_tron_sign_request(struct ExternError*, const char* request_id, const char* sign_data, const char* path, const char* xfp, const char* token_info, const char* origin, const int64_t timestamp);
const char* parse_tron_signature(struct ExternError*, const char* ur_type, const char* cbor_hex);

// Aptos
const char* generate_aptos_sign_request(struct ExternError*, const char* request_id, const char* sign_data, const char* accounts, const char* origin, const int sign_type);
const char* parse_aptos_signature(struct ExternError*, const char* ur_type, const char* cbor_hex);

// Sui
const char* generate_sui_sign_request(struct ExternError*, const char* request_id, const char* intent_message, const char* accounts, const char* origin);
const char* parse_sui_signature(struct ExternError*, const char* ur_type, const char* cbor_hex);

// Keystone
const char* generate_keystone_sign_request(struct ExternError*, const char* request_id, const int coin_type, const char* sign_data, const char* xfp, const char* origin, const int64_t timestamp);
const char* parse_keystone_sign_result(struct ExternError*, const char* ur_type, const char* cbor_hex);

// Near
const char* generate_near_sign_request(struct ExternError*, const char* request_id, const char* sign_data, const char* path, const char* xfp, const char* account, const char* origin);
const char* parse_near_signature(struct ExternError*, const char* ur_type, const char* cbor_hex);

// Arweave
const char* parse_arweave_account(struct ExternError*, const char* ur_type, const char* cbor_hex);
const char* generate_arweave_sign_request(struct ExternError*, const char* request_id, const char* sign_data, const int sign_type, const int salt_len, const char* xfp, const char* account, const char* origin);
const char* parse_arweave_signature(struct ExternError*, const char* ur_type, const char* cbor_hex);

// Cardano
const char* generate_cardano_sign_request(struct ExternError*, const char* request_id, const char* sign_data, const char* utxos, const char* cert_keys, const char* origin);
const char* parse_cardano_signature(struct ExternError*, const char* ur_type, const char* cbor_hex);

// Zcash
const char* parse_zcash_accounts(struct ExternError*, const char* ur_type, const char* cbor_hex);
const char* parse_zcash_pczt(struct ExternError*, const char* ur_type, const char* cbor_hex);
const char* generate_zcash_pczt(struct ExternError*, const char* pczt_hex);