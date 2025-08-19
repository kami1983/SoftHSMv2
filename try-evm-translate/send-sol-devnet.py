#!/usr/bin/env python3
import os, sys, csv, pathlib
from decimal import Decimal

# 允许直接导入项目内 walletkit
REPO_DIR = pathlib.Path(__file__).resolve().parents[1]
if str(REPO_DIR) not in sys.path:
    sys.path.insert(0, str(REPO_DIR))

from walletkit import Pkcs11Signer, SolTransactor  # noqa: E402


def load_first_two(csv_path: str):
    with open(csv_path, 'r') as f:
        rdr = csv.reader(f)
        next(rdr, None)  # header
        r1 = next(rdr, None)
        r2 = next(rdr, None)
        if not r1 or not r2:
            raise RuntimeError('solana-addresses.csv 需要至少两行数据')
        return {'id1': r1[1], 'addr1': r1[2], 'id2': r2[1], 'addr2': r2[2]}


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
        with open(csv_path, 'r') as f:
            rdr = csv.reader(f); next(rdr, None)
            for row in rdr:
                if len(row) >= 3 and row[1] == from_id:
                    from_addr = row[2]; break
    if not from_addr:
        print('未找到 from_id 对应地址', file=sys.stderr); sys.exit(1)

    to_addr = sys.argv[3] if len(sys.argv) >= 4 else info['addr2']

    lamports = int(amount_sol * Decimal(10**9))

    signer = Pkcs11Signer(module_path=module_path, user_pin=user_pin)
    sol = SolTransactor(signer=signer, rpc_url=rpc_url)

    sig_b58 = sol.transfer(from_key_id=from_id, from_addr=from_addr, to_addr=to_addr, lamports=lamports)
    print('transaction signature:', sig_b58)
    print('explorer: https://solscan.io/tx/{}?cluster=devnet'.format(sig_b58))


if __name__ == '__main__':
    main()