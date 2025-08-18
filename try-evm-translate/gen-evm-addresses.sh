#!/usr/bin/env bash
set -euo pipefail

# Inputs
NUM=${1:-10}
LABEL_PREFIX=${2:-user-}
START=${3:-1}

# Paths
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
MODULE="$REPO_DIR/.local/lib/softhsm/libsofthsm2.dylib"
OUT_DIR="$(cd "$(dirname "$0")" && pwd)"
PUB_DIR="$OUT_DIR/pubkeys"

# Env checks
if [[ -z "${SOFTHSM2_CONF:-}" ]]; then
  echo "SOFTHSM2_CONF not set. Please export it to your local config path." >&2
  exit 1
fi
if ! command -v pkcs11-tool >/dev/null 2>&1; then
  echo "pkcs11-tool not found. Install OpenSC (brew install opensc)." >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 not found." >&2
  exit 1
fi
if [[ -z "${USER_PIN:-}" ]]; then
  echo "USER_PIN env not set." >&2
  exit 1
fi

mkdir -p "$PUB_DIR"
CSV="$OUT_DIR/evm-addresses.csv"
echo "label,id,address,address_eip55" > "$CSV"

# Python helper (compute EVM address from SPKI DER)
PY_HELPER=$(cat <<'PY'
import sys
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.backends import default_backend
from eth_utils import keccak, to_checksum_address

spki_path = sys.argv[1]
with open(spki_path, 'rb') as f:
    pub = serialization.load_der_public_key(f.read(), backend=default_backend())
uc = pub.public_bytes(
    encoding=serialization.Encoding.X962,
    format=serialization.PublicFormat.UncompressedPoint,
)
xy = uc[1:]
addr = '0x' + keccak(xy)[-20:].hex()
print(addr, to_checksum_address(addr))
PY
)

pad4() { printf "%04d" "$1"; }

for ((i=0;i<NUM;i++)); do
  id_dec=$((START + i))
  id="$(pad4 "$id_dec")"
  label="${LABEL_PREFIX}${id}"

  # Try export pubkey first; if not exists, generate then export
  der="$PUB_DIR/${label}-pub.der"
  if ! pkcs11-tool --module "$MODULE" -r --type pubkey --id "$id" -o "$der" --pin "$USER_PIN" >/dev/null 2>&1; then
    # Generate keypair (secp256k1)
    pkcs11-tool --module "$MODULE" -l --pin "$USER_PIN" \
      --keypairgen --key-type EC:secp256k1 \
      --label "$label" --id "$id"
    # Export public key (SPKI DER)
    pkcs11-tool --module "$MODULE" -r --type pubkey --id "$id" -o "$der" --pin "$USER_PIN"
  fi

  # Compute address
  read addr addr55 < <(python3 -c "$PY_HELPER" "$der")
  echo "$label,$id,$addr,$addr55" >> "$CSV"
  echo "$label => $addr55"
done

echo "Done. See $CSV and $PUB_DIR/*.der"

