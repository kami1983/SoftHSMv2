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
bash gen-addresses.sh 10 user- 1

# 输出文件：
# - evm-addresses.csv  (label,id,address,address_eip55)
# - pubkeys/           (导出的 SPKI DER 公钥)
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

参数说明：
- 第1参：生成数量（默认 10）
- 第2参：label 前缀（默认 `user-`）
- 第3参：起始 id（默认 1；脚本内部会补零为4位，如 0001）

注意：
- 请确保 `USER_PIN` 已设置且正确；脚本会通过 `pkcs11-tool` 登录。
- 如需自定义模块路径或曲线，可编辑 `gen-addresses.sh` 内的变量。

* 查看方式：
```
# 摘要（32B）
wc -c HelloWorld.txt.digest.bin
hexdump -C HelloWorld.txt.digest.bin

# r / s
echo r: $(hexdump -v -e '32/1 "%02x"' -n 32 HelloWorld.txt.sig_0001.rs.bin)
echo s: $(tail -c +33 HelloWorld.txt.sig_0001.rs.bin | hexdump -v -e '32/1 "%02x"')
```

