#!/usr/bin/env python3
import os, sys, csv, subprocess, tempfile, pathlib
from decimal import Decimal
from web3 import Web3

# 允许直接导入项目内 walletkit
REPO_DIR = pathlib.Path(__file__).resolve().parents[1]
if str(REPO_DIR) not in sys.path:
    sys.path.insert(0, str(REPO_DIR))

from walletkit import Pkcs11Signer, EvmTransactor  # noqa: E402


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

    # 使用 walletkit 进行签名打包
    signer = Pkcs11Signer(module_path=module_path, user_pin=user_pin)
    evm = EvmTransactor(signer, chain_id)

    payload = EvmTransactor.eip1559_payload(
        chain_id, nonce, max_priority, max_fee, gas_limit,
        bytes.fromhex(recipient[2:]), value, data, access_list
    )
    raw_tx = evm.sign_eip1559(key_id=from_id, payload=payload, from_address_checksum=sender)

    tx_hash = w3.eth.send_raw_transaction(raw_tx)
    tx_hex = '0x' + tx_hash.hex()
    print('tx hash:', tx_hex)
    print('explorer: https://sepolia.etherscan.io/tx/' + tx_hex)


if __name__ == '__main__':
    main()

