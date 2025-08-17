#!/usr/bin/env bash
set -euo pipefail

# Usage: sign-message.sh <message_file> [key_id]
# - message_file: 要签名的文本文件（原文将做 EIP-191 前缀后 Keccak-256）
# - key_id: 可选，CKA_ID（如 0001）。未提供时，从 evm-addresses.csv 第一行读取 id。

MSG_FILE=${1:-}
REQ_ID=${2:-}

if [[ -z "${MSG_FILE}" || ! -f "${MSG_FILE}" ]]; then
  echo "Usage: $0 <message_file> [key_id]" >&2
  exit 1
fi

# Paths
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
MODULE="${REPO_DIR}/.local/lib/softhsm/libsofthsm2.dylib"
CSV="${SCRIPT_DIR}/evm-addresses.csv"

# Env checks
if [[ -z "${SOFTHSM2_CONF:-}" ]]; then
  echo "SOFTHSM2_CONF not set." >&2
  exit 1
fi
if [[ -z "${USER_PIN:-}" ]]; then
  echo "USER_PIN env not set." >&2
  exit 1
fi
command -v pkcs11-tool >/dev/null 2>&1 || { echo "pkcs11-tool not found" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found" >&2; exit 1; }

# Resolve key id
KEY_ID="${REQ_ID}"
if [[ -z "${KEY_ID}" ]]; then
  if [[ ! -f "${CSV}" ]]; then
    echo "${CSV} not found, provide key_id explicitly." >&2
    exit 1
  fi
  # Skip header, take first data row
  KEY_ID=$(awk -F, 'NR==2 {print $2}' "${CSV}")
  if [[ -z "${KEY_ID}" ]]; then
    echo "No ID found in ${CSV}." >&2
    exit 1
  fi
fi

# Build digest (EIP-191 personal_sign prefix + Keccak-256)
DIGEST_BIN="${MSG_FILE}.digest.bin"
python3 - "$MSG_FILE" <<'PY'
from eth_utils import keccak
import sys, os
path = sys.argv[1]
with open(path, 'rb') as f:
    m = f.read()
prefix = f"\x19Ethereum Signed Message:\n{len(m)}".encode() + m
open(path+".digest.bin", 'wb').write(keccak(prefix))
print("digest=", open(path+".digest.bin",'rb').read().hex())
PY

# Sign via PKCS#11 (CKM_ECDSA), output r||s (64 bytes)
SIG_BIN="${MSG_FILE}.sig_${KEY_ID}.rs.bin"
pkcs11-tool --module "${MODULE}" -l --pin "${USER_PIN}" \
  --id "${KEY_ID}" --mechanism ECDSA --sign \
  -i "${DIGEST_BIN}" -o "${SIG_BIN}" --signature-format rs

echo "r=$(hexdump -v -e '32/1 "%02x"' -n 32 "${SIG_BIN}")"
echo "s=$(tail -c +33 "${SIG_BIN}" | hexdump -v -e '32/1 "%02x"')"
echo "signature(rs) saved at: ${SIG_BIN}"

