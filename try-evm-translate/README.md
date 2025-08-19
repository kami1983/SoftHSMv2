## try-evm-translate

用于本地测试批量生成 EVM（以太坊）地址，基于 SoftHSMv2（PKCS#11）。

### 先决条件

- 已按仓库根目录的 `install.md` 完成安装与初始化；确保：
  - `SOFTHSM2_CONF` 已指向本地配置（如 `export SOFTHSM2_CONF=<repo>/.local/etc/softhsm2.conf`）
  - 已有可用的用户 PIN（USER_PIN）
- 安装 `pkcs11-tool` 与 Python 依赖（参考 `howtogenevmaddress.md` 前置条件）
  - 如需签名验证，还需安装：`python -m pip install eth_keys`

### 快速开始

```bash
# 设置环境（示例）
export SOFTHSM2_CONF=$(cd .. && pwd)/.local/etc/softhsm2.conf
export USER_PIN='123456'          # 替换为你的用户 PIN

# 生成 10 个地址，label 前缀为 user-，从 id=0001 开始
bash gen-evm-addresses.sh 10 user- 1

# 输出文件：
# - evm-addresses.csv  (label,id,address,address_eip55)
# - pubkeys/           (导出的 SPKI DER 公钥)
```

### 批量生成 Solana 地址（Ed25519）

```bash
# 依赖：requirements.txt 已包含 base58
# 环境：复用前述 SOFTHSM2_CONF 与 USER_PIN

# 生成 5 个地址，label 前缀为 sol-，从 id=0001 开始
bash gen-solana-addresses.sh 5 sol- 1

# 输出文件：
# - solana-addresses.csv  (label,id,address_base58)
# - solana-pubkeys/       (Ed25519 SPKI DER 公钥)
```

### 文本消息签名（EIP-191 personal_sign）

依赖与环境同上；使用 CSV 第一行的 id，或显式指定 id：

```bash
# 准备消息文件
echo -n 'HelloWorld' > HelloWorld.txt

# 使用 CSV 第一行 id
bash sign-message.sh HelloWorld.txt

# 或显式指定 id（如 0001）
bash sign-message.sh HelloWorld.txt 0001

# 产物：
# - HelloWorld.txt.digest.bin   (32 字节 Keccak-256 摘要)
# - HelloWorld.txt.sig_0001.rs.bin  (r||s，64 字节)
# 终端会打印 r、s 的十六进制值
```

### 验证签名（地址恢复匹配）

需要 `eth_keys`：
```bash
python -m pip install eth_keys

# 使用显式签名文件路径
bash verify-message.sh HelloWorld.txt 0xf08C795D5420C3892f0Df81343Bb65B5b680083C \
  ./HelloWorld.txt.sig_0001.rs.bin

# 或省略签名文件（脚本会尝试从 CSV 第一行 id 推断，或匹配 <message>.sig_*.rs.bin 的第一个）
bash verify-message.sh HelloWorld.txt 0xf08C795D5420C3892f0Df81343Bb65B5b680083C
```

输出包含尝试的 v 值与恢复出的地址；匹配则显示 `VERIFY OK`。

### 在 Sepolia 转账（HSM 签名 EIP-1559）

依赖（在你的 Python 环境中安装一次）：
```bash
python -m pip install web3 rlp eth_keys
```

环境变量（示例，按需替换）：
```bash
export SOFTHSM2_CONF=$(cd .. && pwd)/.local/etc/softhsm2.conf
export USER_PIN='你的PIN'
export SEPOLIA_RPC_URL='https://sepolia.infura.io/v3/<你的API密钥>'  # 或其他 RPC
```

运行示例：
```bash
# 从 CSV 第一行地址转给第二行地址 0.001 ETH
python send-eth-sepolia.py 0.001

# 或显式指定 from/to 的 id（即 CSV 第二列 CKA_ID）
python send-eth-sepolia.py 0.001 0001 0002
```

脚本会：
- 读取 `evm-addresses.csv` 定位 from/to 地址与 id
- 连接 RPC 获取 nonce、base fee，构造 EIP‑1559 交易（gas=21000，max_priority=1.5 gwei，max_fee≈2×base_fee+priority）
- 用 `pkcs11-tool` 调用 HSM 私钥（CKM_ECDSA）对交易哈希签名，并做 EIP‑2 低‑s 规范化
- 广播交易并输出 tx hash 与 Etherscan 链接

注意：
- 确保 from 地址在 Sepolia 有足够余额（金额 + 矿工费）
- 如需调整 gas 参数，可编辑 `send-eth-sepolia.py` 内的相关变量

参数说明：
- 第1参：生成数量（默认 10）
- 第2参：label 前缀（默认 `user-`）
- 第3参：起始 id（默认 1；脚本内部会补零为4位，如 0001）

注意：
- 请确保 `USER_PIN` 已设置且正确；脚本会通过 `pkcs11-tool` 登录。
- 如需自定义模块路径或曲线，可编辑 `gen-addresses.sh` 内的变量。

* 查看方式：

### 在 Solana Devnet 转账（HSM 签名 Ed25519）

依赖（在你的 Python 环境中安装一次）：
```bash
python -m pip install solders requests
```

环境变量（示例，按需替换）：
```bash
export SOFTHSM2_CONF=$(cd .. && pwd)/.local/etc/softhsm2.conf
export USER_PIN='你的PIN'
export SOLANA_RPC_URL='https://api.devnet.solana.com'  # 可不设，默认为 devnet
```

准备地址（见“批量生成 Solana 地址”小节，生成 `solana-addresses.csv`）：

运行示例：
```bash
# 从 CSV 第一行地址转给第二行地址 0.1 SOL（单位：SOL）
python send-sol-devnet.py 0.1

# 或显式指定 from_id 与目标地址（Base58）
python send-sol-devnet.py 0.1 1001 <目标Base58地址>
```

脚本会：
- 读取 `solana-addresses.csv` 定位 from/to 地址与 id
- 获取区块哈希、构造转账消息（legacy Message）
- 用 PKCS#11（EDDSA/Ed25519）在 HSM 内签名，组装原始交易并通过 JSON‑RPC 广播
- 输出交易签名与 Solscan 链接（Devnet）
```
# 摘要（32B）
wc -c HelloWorld.txt.digest.bin
hexdump -C HelloWorld.txt.digest.bin

# r / s
echo r: $(hexdump -v -e '32/1 "%02x"' -n 32 HelloWorld.txt.sig_0001.rs.bin)
echo s: $(tail -c +33 HelloWorld.txt.sig_0001.rs.bin | hexdump -v -e '32/1 "%02x"')
```

