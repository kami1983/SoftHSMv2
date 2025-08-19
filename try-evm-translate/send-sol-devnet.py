#!/usr/bin/env python3
import os, sys, csv, pathlib, tempfile, subprocess, base64
from decimal import Decimal
from solders.pubkey import Pubkey
from solders.system_program import transfer, TransferParams
from solders.message import Message
from solders.hash import Hash
import requests


def load_first_two(csv_path: str):
    with open(csv_path, 'r') as f:
        rdr = csv.reader(f)
        next(rdr, None)  # header
        r1 = next(rdr, None)
        r2 = next(rdr, None)
        if not r1 or not r2:
            raise RuntimeError('solana-addresses.csv 需要至少两行数据')
        return {'id1': r1[1], 'addr1': r1[2], 'id2': r2[1], 'addr2': r2[2]}


def resolve_blockhash_via_http(rpc_url: str) -> str:
    headers = {"Content-Type": "application/json"}
    # Try getLatestBlockhash first
    payload = {"jsonrpc": "2.0", "id": 1, "method": "getLatestBlockhash", "params": [{"commitment": "finalized"}]}
    r = requests.post(rpc_url, json=payload, headers=headers, timeout=10)
    if r.ok:
        j = r.json()
        if "result" in j and "value" in j["result"] and "blockhash" in j["result"]["value"]:
            return j["result"]["value"]["blockhash"]
    # Fallback to deprecated getRecentBlockhash
    payload = {"jsonrpc": "2.0", "id": 1, "method": "getRecentBlockhash", "params": []}
    r = requests.post(rpc_url, json=payload, headers=headers, timeout=10)
    r.raise_for_status()
    j = r.json()
    return j["result"]["value"]["blockhash"]


def shortvec_encode(n: int) -> bytes:
    # Solana short vector (compact-u16 style)
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            break
    return bytes(out)


def main():
    script_dir = pathlib.Path(__file__).resolve().parent
    repo_dir = script_dir.parent
    csv_path = script_dir / 'solana-addresses.csv'

    module_path = os.environ.get('MODULE', str(repo_dir / '.local/lib/softhsm/libsofthsm2.dylib'))
    softhsm_conf = os.environ.get('SOFTHSM2_CONF')
    user_pin = os.environ.get('USER_PIN')
    rpc_url = os.environ.get('SOLANA_RPC_URL', 'https://api.devnet.solana.com')

    if not softhsm_conf:
        print('SOFTHSM2_CONF 未设置', file=sys.stderr); sys.exit(1)
    if not user_pin:
        print('USER_PIN 未设置', file=sys.stderr); sys.exit(1)

    if len(sys.argv) < 2:
        print('用法: send-sol-devnet.py <amount_SOL> [from_id] [to_base58]', file=sys.stderr)
        sys.exit(1)
    amount_sol = Decimal(sys.argv[1])

    info = load_first_two(str(csv_path))
    from_id = sys.argv[2] if len(sys.argv) >= 3 else info['id1']
    from_addr = info['addr1'] if from_id == info['id1'] else None
    if from_addr is None:
        # 扫描 CSV
        with open(csv_path, 'r') as f:
            rdr = csv.reader(f); next(rdr, None)
            for row in rdr:
                if len(row) >= 3 and row[1] == from_id:
                    from_addr = row[2]; break
    if not from_addr:
        print('未找到 from_id 对应地址', file=sys.stderr); sys.exit(1)

    to_addr = sys.argv[3] if len(sys.argv) >= 4 else info['addr2']

    recent_blockhash = resolve_blockhash_via_http(rpc_url)

    from_pub = Pubkey.from_string(from_addr)
    to_pub = Pubkey.from_string(to_addr)
    lamports = int(amount_sol * Decimal(10**9))

    # 构建 legacy Message（solders）
    ix = transfer(TransferParams(from_pubkey=from_pub, to_pubkey=to_pub, lamports=lamports))
    msg = Message.new_with_blockhash([ix], from_pub, Hash.from_string(recent_blockhash))
    msg_bytes = bytes(msg)

    # 使用 HSM 通过 PKCS#11 EDDSA 签名
    with tempfile.NamedTemporaryFile(delete=False) as tf_in, tempfile.NamedTemporaryFile(delete=False) as tf_out:
        tf_in.write(msg_bytes)
        tf_in.flush()
        cmd = [
            'pkcs11-tool', '--module', module_path,
            '-l', '--pin', user_pin,
            '--id', from_id, '--mechanism', 'EDDSA', '--sign',
            '-i', tf_in.name, '-o', tf_out.name
        ]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            print('签名失败:', r.stderr, file=sys.stderr); sys.exit(1)
        sig_bytes = pathlib.Path(tf_out.name).read_bytes()
    if len(sig_bytes) != 64:
        print('签名长度错误，应为64字节（Ed25519）', file=sys.stderr); sys.exit(1)

    # 组装原始交易：<sig_count><64B签名...><message_bytes>
    raw_tx = shortvec_encode(1) + sig_bytes + msg_bytes

    # 通过 JSON-RPC 发送 base64 编码交易
    payload = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "sendTransaction",
        "params": [base64.b64encode(raw_tx).decode(), {"encoding": "base64"}],
    }
    resp = requests.post(rpc_url, json=payload, headers={"Content-Type": "application/json"}, timeout=15)
    resp.raise_for_status()
    j = resp.json()
    if 'error' in j and j['error']:
        print('广播失败:', j['error'], file=sys.stderr); sys.exit(1)
    sig_b58 = j['result']
    print('transaction signature:', sig_b58)
    print('explorer: https://solscan.io/tx/{}?cluster=devnet'.format(sig_b58))


if __name__ == '__main__':
    main()