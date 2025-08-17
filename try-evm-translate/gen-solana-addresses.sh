#!/usr/bin/env bash
set -euo pipefail

# Inputs
NUM=${1:-10}
LABEL_PREFIX=${2:-sol-}
START=${3:-1}

# Paths
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
MODULE="$REPO_DIR/.local/lib/softhsm/libsofthsm2.dylib"
OUT_DIR="$(cd "$(dirname "$0")" && pwd)"
PUB_DIR="$OUT_DIR/solana-pubkeys"

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
CSV="$OUT_DIR/solana-addresses.csv"
echo "label,id,address_base58" > "$CSV"

# Python helper (compute Solana address from SPKI DER Ed25519)
PY_HELPER=$(cat <<'PY'
import sys
from cryptography.hazmat.primitives import serialization
import base58

def extract_raw_from_spki(spki: bytes) -> bytes:
    # Try cryptography Ed25519 path
    try:
        pub = serialization.load_der_public_key(spki)
        # Ed25519PublicKey supports Raw output
        return pub.public_bytes(encoding=serialization.Encoding.Raw,
                                format=serialization.PublicFormat.Raw)
    except Exception:
        # Fallback: minimal ASN.1 parse to get subjectPublicKey BIT STRING bytes
        # SPKI = SEQUENCE { algorithm, subjectPublicKey BIT STRING }
        b = spki
        i = 0
        if b[i] != 0x30:
            raise ValueError('Not a SEQUENCE')
        i += 1
        # read length
        l = b[i]; i += 1
        if l & 0x80:
            n = l & 0x7F
            l = int.from_bytes(b[i:i+n], 'big'); i += n
        # algorithm identifier (skip)
        # find BIT STRING tag 0x03
        j = b.find(b"\x03", i)
        if j == -1:
            raise ValueError('BIT STRING not found')
        i = j + 1
        # length of BIT STRING
        l = b[i]; i += 1
        if l & 0x80:
            n = l & 0x7F
            l = int.from_bytes(b[i:i+n], 'big'); i += n
        # first content byte = number of unused bits (should be 0)
        if b[i] != 0x00:
            raise ValueError('Unexpected unused bits')
        i += 1
        raw = b[i:i+(l-1)]
        if len(raw) != 32:
            raise ValueError('Unexpected raw length')
        return raw

spki_path = sys.argv[1]
with open(spki_path, 'rb') as f:
    spki = f.read()
raw = extract_raw_from_spki(spki)
print(base58.b58encode(raw).decode())
PY
)

pad4() { printf "%04d" "$1"; }

for ((i=0;i<NUM;i++)); do
  id_dec=$((START + i))
  id="$(pad4 "$id_dec")"
  label="${LABEL_PREFIX}${id}"

  der="$PUB_DIR/${label}-pub.der"
  # Try export; if not exists, generate then export
  if ! pkcs11-tool --module "$MODULE" -r --type pubkey --id "$id" -o "$der" --pin "$USER_PIN" >/dev/null 2>&1; then
    # Generate Ed25519 keypair
    pkcs11-tool --module "$MODULE" -l --pin "$USER_PIN" \
      --keypairgen --key-type EC:ed25519 \
      --label "$label" --id "$id"
    pkcs11-tool --module "$MODULE" -r --type pubkey --id "$id" -o "$der" --pin "$USER_PIN"
  fi

  if ! addr=$(python3 -c "$PY_HELPER" "$der"); then
    # Fallback: read EC_POINT via pkcs11-tool list output and decode DER OCTET STRING (0x04,len,32bytes)
    ec_point_hex=$(pkcs11-tool --module "$MODULE" -O --type pubkey --id "$id" 2>/dev/null | awk '/EC_POINT:/ {print $2$3$4$5$6$7$8$9$10$11$12$13$14$15$16$17$18$19$20}' | tr -d ' ')
    if [[ -z "$ec_point_hex" ]]; then
      echo "id=$id 无法获取 EC_POINT。" >&2; exit 1
    fi
    if ! addr=$(python3 - "$ec_point_hex" <<'PY'
import sys, base58, binascii
h=sys.argv[1].lower()
if h.startswith('0x'): h=h[2:]
data=bytes.fromhex(h)
# Expect DER OCTET STRING: 0x04, length, then raw (32 bytes)
if len(data)>=2 and data[0]==0x04:
    l=data[1]
    raw=data[2:2+l]
    if len(raw)!=32:
        raise SystemExit('bad raw len')
else:
    # If provider already returned raw 32 bytes
    raw=data
    if len(raw)!=32:
        raise SystemExit('bad raw len')
print(base58.b58encode(raw).decode())
PY
    ); then
      echo "id=$id 导出的公钥不是 Ed25519 或格式不兼容。请更换未占用的 id。" >&2; exit 1
    fi
  fi
  echo "$label,$id,$addr" >> "$CSV"
  echo "$label => $addr"
done

echo "Done. See $CSV and $PUB_DIR/*.der"

