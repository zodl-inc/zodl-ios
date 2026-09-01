#!/usr/bin/env python3
"""Sign a SHA256 checksum file with an Ed25519 private key.

Usage: sign-checksum.py <private_key.pem> <checksum_file>

Reads the raw hex SHA256 from the checksum file, signs it with the
Ed25519 key, and writes a base64-encoded signature to
<checksum_file>.sig.b64.
"""
import sys
from pathlib import Path
from cryptography.hazmat.primitives.serialization import load_pem_private_key
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
import base64

def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <private_key.pem> <checksum_file>")
        sys.exit(1)

    key_path = Path(sys.argv[1])
    checksum_path = Path(sys.argv[2])

    key_data = key_path.read_bytes()
    private_key = load_pem_private_key(key_data, password=None)
    if not isinstance(private_key, Ed25519PrivateKey):
        print("Error: key is not Ed25519")
        sys.exit(1)

    checksum_hex = checksum_path.read_text().strip()
    message = checksum_hex.encode()

    signature = private_key.sign(message)
    sig_b64 = base64.b64encode(signature).decode()

    out_path = checksum_path.with_suffix(checksum_path.suffix + ".sig.b64")
    out_path.write_text(sig_b64 + "\n")
    print(f"Signed: {out_path} ({len(signature)} bytes)")

if __name__ == "__main__":
    main()
