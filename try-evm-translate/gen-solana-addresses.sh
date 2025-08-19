#!/usr/bin/env bash
set -euo pipefail

# Inputs
NUM=${1:-5}
LABEL_PREFIX=${2:-sol-}
START=${3:-1001}

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

pad4() { printf "%04d" "$1"; }

for ((i=0;i<NUM;i++)); do
  id_dec=$((START + i))
  id="$(pad4 "$id_dec")"
  label="${LABEL_PREFIX}${id}"
  der="$PUB_DIR/${label}-pub.der"

  # 调用 walletkit 生成 Ed25519 地址
  out_line=$(python3 - "$REPO_DIR" "$MODULE" "$USER_PIN" "$id" "$label" "$der" <<'PY'
import sys
repo, mod, pin, kid, label, out = sys.argv[1:7]
if repo not in sys.path:
    sys.path.insert(0, repo)
from walletkit.sol import generate_address
addr, spki = generate_address(mod, pin, kid, label)
open(out, 'wb').write(spki)
print(addr)
PY
)
  if [[ -z "$out_line" ]]; then
    echo "id=$id 生成失败" >&2; exit 1
  fi
  echo "$label,$id,$out_line" >> "$CSV"
  echo "$label => $out_line"

done

echo "Done. See $CSV and $PUB_DIR/*.der"

