## 使用 SoftHSMv2 生成以太坊接收地址（EVM 地址）

目标：在不导出私钥的前提下，为每个用户生成 secp256k1 密钥对，并导出对应以太坊地址。

### 前置条件

- 已按 `install.md` 安装并初始化一个可用的 token；确保：
  - 模块库：`./.local/lib/softhsm/libsofthsm2.dylib`
  - 工具：`./.local/bin/softhsm2-util`
  - 配置：`./.local/etc/softhsm2.conf`
  - 导出配置环境变量：
    ```bash
    export SOFTHSM2_CONF=$PWD/.local/etc/softhsm2.conf
    ```
- 安装 OpenSC 的 `pkcs11-tool`（用于生成密钥/读取公钥）与 Python 库（用于计算以太坊地址）：
  ```bash
  # 自检并安装
  if ! command -v pkcs11-tool >/dev/null 2>&1; then
    brew install opensc
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    brew install python3
  fi
  python3 -m pip install --upgrade cryptography eth_utils 'eth-hash[pycryptodome]' pycryptodome
  ```

可选：使用 Conda 建立隔离环境（推荐避免与系统 Python 包冲突）：

```bash
conda create -n evmaddr python=3.11 -y
conda activate evmaddr
python -m pip install --upgrade pip
python -m pip install cryptography eth_utils 'eth-hash[pycryptodome]' pycryptodome
# 验证
python - <<'PY'
from eth_utils import keccak
from Crypto.Hash import keccak as k2
import cryptography
print('ok')
PY
```

* 特别提示：`pkcs11-tool` 通过 `--module` 指定要加载的 PKCS#11 模块，下面命令把操作“接到” SoftHSM2：
  ```bash
  pkcs11-tool --module $PWD/.local/lib/softhsm/libsofthsm2.dylib --list-slots
  ```
  `pkcs11-tool` 是 OpenSC 的命令行工具（C 实现），不是 Python 工具。

提示：secp256k1 曲线支持由加密后端决定。若当前 OpenSSL 构建不支持 secp256k1，请用 Botan 后端重建（见 `install.md` 中 `--with-crypto-backend=botan`）。

### 步骤一：为用户生成 secp256k1 密钥对

使用 PKCS#11 在 HSM 内生成（默认私钥不可导出）。示例为用户 ID 0001：

```bash
MODULE="$PWD/.local/lib/softhsm/libsofthsm2.dylib"
USER_PIN="123456"   # 替换为你的用户 PIN

pkcs11-tool --module "$MODULE" -l --pin "$USER_PIN" \
  --keypairgen --key-type EC:secp256k1 \
  --label "user-0001" --id 0001
```

说明：
- `--label` 与 `--id` 用于检索和区分对象，与密钥材料无关。
- 若报曲线不支持，请改用 Botan 后端或确认 OpenSSL 曲线集。

### 步骤二：导出公钥（X.509 SPKI DER）

```bash
pkcs11-tool --module "$MODULE" -r --type pubkey --id 0001 -o user-0001-pub.der --pin "$USER_PIN"
```

生成的 `user-0001-pub.der` 为 X.509 SubjectPublicKeyInfo（SPKI）格式。

### 步骤三：从公钥计算以太坊地址

以太坊地址计算规则：取未压缩公钥的 (X||Y)（不含 0x04 前缀），做 Keccak-256，取最后 20 字节，再加 `0x` 前缀（可选 EIP-55 校验和）。

示例脚本（保存为 `evm_addr.py`）：

```python
import sys
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.backends import default_backend
from eth_utils import keccak, to_checksum_address

spki_der_path = sys.argv[1]

with open(spki_der_path, 'rb') as f:
    pub = serialization.load_der_public_key(f.read(), backend=default_backend())

# 提取未压缩形式的公钥字节（0x04 || X || Y）
uc = pub.public_bytes(
    encoding=serialization.Encoding.X962,
    format=serialization.PublicFormat.UncompressedPoint,
)
if uc[0] != 0x04 or len(uc) not in (65, 97):
    raise ValueError('invalid uncompressed EC point')

xy = uc[1:]  # 去掉 0x04 前缀，得到 X||Y
addr_bytes = keccak(xy)[-20:]
addr_hex = '0x' + addr_bytes.hex()
print(addr_hex, to_checksum_address(addr_hex))
```

运行：
```bash
python3 evm_addr.py user-0001-pub.der
```
输出两列：
- 原始小写地址（`0x`+40hex）
- EIP-55 checksum 地址

### 批量生成示例

```bash
for n in $(seq -w 1 10); do
  id="$n"
  label="user-$n"
  pkcs11-tool --module "$MODULE" -l --pin "$USER_PIN" \
    --keypairgen --key-type EC:secp256k1 \
    --label "$label" --id "$id"
  pkcs11-tool --module "$MODULE" -r --type pubkey --id "$id" -o "$label-pub.der" --pin "$USER_PIN"
  python3 evm_addr.py "$label-pub.der" | awk -v L=$label '{print L, $1, $2}'
done > evm-addresses.txt
```

`evm-addresses.txt` 将记录 label 与地址的对应关系。

### 消息签名（EIP-191 personal_sign 示例）

以下示例演示如何对字符串进行 EIP-191 风格消息签名（即 `"\x19Ethereum Signed Message:\n{len(m)}"+m` 后做 Keccak-256，再做 ECDSA/secp256k1 签名）。

```bash
MODULE="$PWD/.local/lib/softhsm/libsofthsm2.dylib"
USER_PIN="123456"   # 替换为你的用户 PIN
KEY_ID=0001          # 生成密钥时指定的 --id

echo -n "Helloword" > msg.txt
python - <<'PY'
from eth_utils import keccak
m = open('msg.txt','rb').read()
prefix = f"\x19Ethereum Signed Message:\n{len(m)}".encode() + m
open('digest.bin','wb').write(keccak(prefix))
PY

# 用 HSM 私钥签名（输出 r||s，64 字节）
pkcs11-tool --module "$MODULE" -l --pin "$USER_PIN" \
  --id $KEY_ID --mechanism ECDSA --sign \
  -i digest.bin -o sig_rs.bin --signature-format rs

# 查看 r、s（十六进制）
echo r: $(hexdump -v -e '32/1 "%02x"' -n 32 sig_rs.bin)
echo s: $(tail -c +33 sig_rs.bin | hexdump -v -e '32/1 "%02x"')
```

可选：恢复并校验地址（需要 `eth_keys`）

```bash
python -m pip install eth_keys
python - <<'PY'
from eth_keys import keys
from eth_utils import to_checksum_address

addr_expected = "0x...".lower()  # 替换为你的地址
digest = open('digest.bin','rb').read()
rs = open('sig_rs.bin','rb').read()
r, s = int.from_bytes(rs[:32],'big'), int.from_bytes(rs[32:],'big')
for v in (27, 28, 0, 1):
    try:
        sig = keys.Signature(vrs=(v, r, s))
        pub = sig.recover_public_key_from_msg_hash(digest)
        addr = to_checksum_address(pub.to_address())
        print("try v=",v,"=>",addr)
        if addr.lower()==addr_expected: print("MATCH")
    except Exception:
        pass
PY
```

### 注意事项与最佳实践

- 私钥默认不可导出（CKA_EXTRACTABLE=false），确保只在 HSM 内使用签名。
- PIN 务必为高熵随机字符串（≥12–16 位），妥善保管；丢失 PIN 基本无法恢复私钥。
- 备份 token 目录（`directories.tokendir`）以便灾难恢复（见 `howtouse.md` 与前述问答）。
- 若要在链上签名交易：使用支持 PKCS#11 的客户端/中间件，将 secp256k1 签名请求发给 HSM，交易 R/S/V 组装需按以太坊规范处理（超出本文范畴）。

