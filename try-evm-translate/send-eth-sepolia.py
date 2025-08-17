#!/usr/bin/env python3
import os, sys, csv, subprocess, tempfile, pathlib, json
from decimal import Decimal
from eth_utils import keccak, to_checksum_address
from eth_keys import keys
from web3 import Web3
import rlp


def load_csv_first_two(csv_path):
    with open(csv_path, 'r') as f:
        rdr = csv.reader(f)
        header = next(rdr, None)
        row1 = next(rdr, None)
        row2 = next(rdr, None)
        if not row1 or not row2:
            raise RuntimeError('evm-addresses.csv 需要至少两行数据')
        # label,id,address,address_eip55
        return {
            'id1': row1[1], 'addr1': row1[2],
            'id2': row2[1], 'addr2': row2[2],
        }


def to_bytes_address(addr_hex: str) -> bytes:
    ah = Web3.to_checksum_address(addr_hex)
    return bytes.fromhex(ah[2:])


def build_eip1559_sign_payload(chain_id, nonce, max_priority, max_fee, gas, to_addr, value, data=b"", access_list=None):
    if access_list is None:
        access_list = []
    # Types: integers are big-endian without leading 0x00, bytes are raw
    payload = [
        chain_id,
        nonce,
        max_priority,
        max_fee,
        gas,
        to_addr,   # 20-byte or b'' for creation
        value,
        data,
        access_list,
    ]
    return payload


def rlp_encode_eip1559_with_sig(payload, y_parity, r, s) -> bytes:
    lst = payload + [y_parity, r, s]
    return b"\x02" + rlp.encode(lst)


def main():
    repo_dir = pathlib.Path(__file__).resolve().parents[1]
    script_dir = pathlib.Path(__file__).resolve().parent
    csv_path = script_dir / 'evm-addresses.csv'
    module_path = os.environ.get('MODULE', str(repo_dir / '.local/lib/softhsm/libsofthsm2.dylib'))
    softhsm_conf = os.environ.get('SOFTHSM2_CONF')
    user_pin = os.environ.get('USER_PIN')
    rpc_url = os.environ.get('SEPOLIA_RPC_URL')

    if not softhsm_conf:
        print('SOFTHSM2_CONF 未设置', file=sys.stderr); sys.exit(1)
    if not user_pin:
        print('USER_PIN 未设置', file=sys.stderr); sys.exit(1)
    if not rpc_url:
        print('SEPOLIA_RPC_URL 未设置', file=sys.stderr); sys.exit(1)

    # 参数：金额（ETH），可选 from_id,to_id
    if len(sys.argv) < 2:
        print('用法: send-eth-sepolia.py <amount_eth> [from_id] [to_id]', file=sys.stderr)
        sys.exit(1)
    amount_eth = Decimal(sys.argv[1])

    info = load_csv_first_two(str(csv_path))
    from_id = sys.argv[2] if len(sys.argv) >= 3 else info['id1']
    to_id = sys.argv[3] if len(sys.argv) >= 4 else info['id2']
    from_addr = info['addr1'] if from_id == info['id1'] else None
    to_addr = info['addr2'] if to_id == info['id2'] else None

    # 若显式 id 与 CSV 不匹配，简单扫描 CSV 查地址
    if from_addr is None or to_addr is None:
        with open(csv_path, 'r') as f:
            rdr = csv.reader(f)
            next(rdr, None)
            for row in rdr:
                if len(row) >= 4:
                    if row[1] == from_id:
                        from_addr = row[2]
                    if row[1] == to_id:
                        to_addr = row[2]
    if not from_addr or not to_addr:
        print('无法在 CSV 中找到对应地址', file=sys.stderr); sys.exit(1)

    w3 = Web3(Web3.HTTPProvider(rpc_url))
    if not w3.is_connected():
        print('无法连接 RPC', file=sys.stderr); sys.exit(1)

    chain_id = 11155111
    sender = Web3.to_checksum_address(from_addr)
    recipient = Web3.to_checksum_address(to_addr)
    value = int(amount_eth * Decimal(10**18))
    nonce = w3.eth.get_transaction_count(sender)

    pending = w3.eth.get_block('pending')
    base_fee = int(pending.get('baseFeePerGas', w3.eth.gas_price))
    max_priority = Web3.to_wei(1.5, 'gwei')
    max_fee = base_fee * 2 + max_priority
    gas_limit = 21000
    data = b""
    access_list = []

    payload = build_eip1559_sign_payload(
        chain_id, nonce, max_priority, max_fee, gas_limit,
        bytes.fromhex(recipient[2:]), value, data, access_list
    )
    sign_rlp = b"\x02" + rlp.encode(payload)
    digest = keccak(sign_rlp)

    # 调用 pkcs11-tool 以 CKM_ECDSA 签名 digest
    with tempfile.NamedTemporaryFile(delete=False) as tf_in, tempfile.NamedTemporaryFile(delete=False) as tf_out:
        tf_in.write(digest)
        tf_in.flush()
        cmd = [
            'pkcs11-tool', '--module', module_path,
            '-l', '--pin', user_pin,
            '--id', from_id, '--mechanism', 'ECDSA', '--sign',
            '-i', tf_in.name, '-o', tf_out.name, '--signature-format', 'rs'
        ]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            print('签名失败:', r.stderr, file=sys.stderr); sys.exit(1)
        sig = pathlib.Path(tf_out.name).read_bytes()
    if len(sig) != 64:
        print('签名长度错误，应为64字节 r||s', file=sys.stderr); sys.exit(1)
    r_int = int.from_bytes(sig[:32], 'big')
    s_int = int.from_bytes(sig[32:], 'big')

    # 恢复 yParity (v)
    y_parity = None
    for v in (0, 1):
        try:
            rec = keys.Signature(vrs=(v, r_int, s_int)).recover_public_key_from_msg_hash(digest)
            addr = to_checksum_address(rec.to_address())
            if addr.lower() == sender.lower():
                y_parity = v
                break
        except Exception:
            pass
    if y_parity is None:
        print('无法恢复出发送者地址，签名可能不匹配', file=sys.stderr); sys.exit(1)

    # EIP-2 低S规范化：若 s > n/2，替换为 n - s 并翻转 y_parity
    SECP256K1_N = int("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141", 16)
    HALF_N = SECP256K1_N // 2
    if s_int > HALF_N:
        s_int = SECP256K1_N - s_int
        y_parity ^= 1

    raw_tx = rlp_encode_eip1559_with_sig(payload, y_parity, r_int, s_int)
    tx_hash = w3.eth.send_raw_transaction(raw_tx)
    tx_hex = '0x' + tx_hash.hex()
    print('tx hash:', tx_hex)
    print('explorer: https://sepolia.etherscan.io/tx/' + tx_hex)


if __name__ == '__main__':
    main()

