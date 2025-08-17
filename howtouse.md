## SoftHSMv2 使用说明（快速上手）

本文件演示如何在本仓库已安装的本地前缀下使用 SoftHSMv2。若尚未安装，请先参考 `install.md` 完成安装与初始化环境。

### 前置条件

- 已完成本地安装（见 `install.md`），关键路径：
  - 模块库：`./.local/lib/softhsm/libsofthsm2.dylib`
  - 工具：`./.local/bin/softhsm2-util`
  - 配置：`./.local/etc/softhsm2.conf`
  - token 目录：`./.local/var/lib/softhsm/tokens/`

### 1) 设置环境变量

```bash
export SOFTHSM2_CONF=$PWD/.local/etc/softhsm2.conf
```

说明：`SOFTHSM2_CONF` 用于指向实际配置文件位置，避免默认读取系统 `/etc/softhsm2.conf`。

### 2) 查看可用插槽

```bash
./.local/bin/softhsm2-util --show-slots
```

若显示“free/uninitialized token”，需要先初始化。

### 3) 初始化一个 token（非交互）

```bash
./.local/bin/softhsm2-util \
  --init-token --free \
  --label "My token 1" \
  --so-pin 123456 \
  --pin 123456
```

初始化后可再次查看：

```bash
./.local/bin/softhsm2-util --show-slots
```

### 4) 导入对象示例

- 导入 PKCS#8 私钥（PEM），并自动生成公钥对象：

```bash
./.local/bin/softhsm2-util \
  --import /path/to/keypair.pem \
  --import-type keypair \
  --token "My token 1" \
  --label "my-key" \
  --id 010203 \
  --pin 123456
```

- 导入 AES 密钥（二进制原始文件）：

```bash
./.local/bin/softhsm2-util \
  --import /path/to/aes.key \
  --import-type aes \
  --token "My token 1" \
  --label "my-aes" \
  --id a1b2c3 \
  --pin 123456
```

- 导入证书（X.509 PEM）：

```bash
./.local/bin/softhsm2-util \
  --import /path/to/cert.pem \
  --import-type cert \
  --token "My token 1" \
  --label "my-cert" \
  --id 112233 \
  --pin 123456
```

### 5) 在应用中使用 PKCS#11 模块

大多数使用 PKCS#11 的应用需要模块库路径：

```
<repo>/.local/lib/softhsm/libsofthsm2.dylib
```

常见方式：

- 应用配置中直接填写上面的 PKCS#11 库路径；
- 或通过应用的环境变量/命令行参数指向该库；
- 若使用 `p11-kit` 进行系统集成，请参考 `install.md`，并在系统范围安装与启用对应模块。

### 6) 备份与恢复

- 备份：复制配置中 `directories.tokendir` 对应的目录（本地前缀为 `./.local/var/lib/softhsm/tokens/`）。
- 恢复：停用相关应用后，将备份目录原样拷回该位置。

### 7) 删除 token（不可逆）

```bash
./.local/bin/softhsm2-util --delete-token --token "My token 1"
```

如存在同名 token 或多个匹配项，可结合 `--slot` 或 `--serial` 精确选择。

### 8) 常见问题

- 找不到 token 或“Failed to enumerate object store”：确认 `SOFTHSM2_CONF` 指向正确，且 `directories.tokendir` 存在且可写。
- 应用无法加载模块：确认使用了正确的 PKCS#11 库路径，并且应用进程有权限访问该路径与 token 目录。
- 切换为文件后端（更高吞吐）：编辑 `softhsm2.conf` 将 `objectstore.backend = file`。

更多高级用法（例如密钥生成、会话管理、机制开关等），请参考 `README.md`、`OSX-NOTES.md` 以及工具自带帮助：

```bash
./.local/bin/softhsm2-util --help
```

