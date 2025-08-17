#!/usr/bin/env bash
set -euo pipefail

# Usage: verify-message.sh <message_file> <expected_address> [sig_rs_file]
# - message_file: 被签名的原文
# - expected_address: 预期以太坊地址（0x...，大小写不敏感）
# - sig_rs_file: 可选，r||s 签名文件（64字节）。未提供时，优先从 CSV 第一行取 id 组合路径；否则匹配 <message>.sig_*.rs.bin 中的第一个。

MSG_FILE=${1:-}
EXPECT_ADDR=${2:-}
SIG_BIN_ARG=${3:-}

if [[ -z "${MSG_FILE}" || -z "${EXPECT_ADDR}" ]]; then
  echo "Usage: $0 <message_file> <expected_address> [sig_rs_file]" >&2
  exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CSV="${SCRIPT_DIR}/evm-addresses.csv"

command -v python3 >/dev/null 2>&1 || { echo "python3 not found" >&2; exit 1; }

# 1) 构造/校验 digest
DIGEST_BIN="${MSG_FILE}.digest.bin"
if [[ ! -f "${DIGEST_BIN}" ]]; then
  python3 - "$MSG_FILE" <<'PY'
from eth_utils import keccak
import sys
path = sys.argv[1]
with open(path,'rb') as f: m = f.read()
prefix = f"\x19Ethereum Signed Message:\n{len(m)}".encode() + m
open(path+".digest.bin",'wb').write(keccak(prefix))
PY
fi

# 2) 定位签名文件
SIG_BIN="${SIG_BIN_ARG}"
if [[ -z "${SIG_BIN}" ]]; then
  if [[ -f "${CSV}" ]]; then
    ID=$(awk -F, 'NR==2 {print $2}' "${CSV}" ) || true
    if [[ -n "${ID:-}" ]]; then
      CANDIDATE="${MSG_FILE}.sig_${ID}.rs.bin"
      [[ -f "${CANDIDATE}" ]] && SIG_BIN="${CANDIDATE}"
    fi
  fi
fi
if [[ -z "${SIG_BIN}" ]]; then
  # 取第一个匹配
  CANDIDATE=$(ls -1 "${MSG_FILE}".sig_*.rs.bin 2>/dev/null | head -n1 || true)
  [[ -n "${CANDIDATE}" ]] && SIG_BIN="${CANDIDATE}"
fi
if [[ -z "${SIG_BIN}" || ! -f "${SIG_BIN}" ]]; then
  echo "Signature file not found. Provide it explicitly as third arg." >&2
  exit 1
fi

# 3) 恢复地址并校验
python3 - "$MSG_FILE" "$EXPECT_ADDR" "$SIG_BIN" <<'PY'
import sys
from eth_keys import keys
from eth_utils import to_checksum_address

msg_path, exp_addr, sig_path = sys.argv[1:4]
exp_addr = exp_addr.lower()
digest = open(msg_path+".digest.bin",'rb').read()
rs = open(sig_path,'rb').read()
if len(rs)!=64:
    print("Invalid sig length (need 64 bytes r||s)", file=sys.stderr)
    sys.exit(2)
r, s = int.from_bytes(rs[:32],'big'), int.from_bytes(rs[32:],'big')
ok = False
for v in (27, 28, 0, 1):
    try:
        sig = keys.Signature(vrs=(v, r, s))
        pub = sig.recover_public_key_from_msg_hash(digest)
        addr = to_checksum_address(pub.to_address())
        print(f"try v={v} => {addr}")
        if addr.lower() == exp_addr:
            print("VERIFY OK")
            ok = True
            break
    except Exception:
        pass
if not ok:
    print("VERIFY FAILED", file=sys.stderr)
    sys.exit(1)
PY

