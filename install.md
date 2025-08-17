## SoftHSMv2 本地安装（macOS，非特权前缀）

本说明记录在 macOS 本地（darwin 24，Apple Silicon）从源码构建、安装到项目本地前缀并完成初始化的完整流程。采用 CMake 构建（避免 Autotools 在本机出现的 perl shebang 问题），OpenSSL 作为加密后端，并启用 SQLite 数据库对象存储。

### 1. 安装依赖（Homebrew）

```bash
brew install autoconf automake libtool pkg-config openssl@3 sqlite cppunit p11-kit botan
```

说明：本流程最终使用 CMake 与 OpenSSL@3；安装 Botan/CppUnit 便于备选与测试，需要时可省略。

### 2. CMake 配置与构建

在仓库根目录执行：

```bash
cmake -S . -B build \
  -DWITH_CRYPTO_BACKEND=openssl \
  -DWITH_OBJECTSTORE_BACKEND_DB=ON \
  -DCMAKE_INSTALL_PREFIX=$PWD/.local \
  -DCMAKE_INSTALL_SYSCONFDIR=$PWD/.local/etc \
  -DCMAKE_INSTALL_LOCALSTATEDIR=$PWD/.local/var \
  -DOPENSSL_ROOT_DIR=$(brew --prefix openssl@3) \
  -DENABLE_P11_KIT=OFF \
  -DCMAKE_BUILD_TYPE=Release

cmake --build build -j
```

注：`-DCMAKE_INSTALL_SYSCONFDIR` 与 `-DCMAKE_INSTALL_LOCALSTATEDIR` 指向项目内，避免写入系统 `/etc` 与 `/var`。

### 3. 安装至本地前缀

```bash
cmake --install build
```

安装产物关键路径：

- PKCS#11 模块：`./.local/lib/softhsm/libsofthsm2.dylib`
- 工具：`./.local/bin/softhsm2-util`、`softhsm2-keyconv`、`softhsm2-dump-*`、`softhsm2-migrate`
- 配置：`./.local/etc/softhsm2.conf`
- token 目录：`./.local/var/lib/softhsm/tokens/`

### 4. 配置文件调整

将默认配置中的 token 目录与对象存储后端指向本地路径与 SQLite：

```bash
perl -0777 -pe 's#^directories\.tokendir\s*=.*#directories.tokendir = '$PWD'/.local/var/lib/softhsm/tokens/#m; s#^objectstore\.backend\s*=.*#objectstore.backend = db#m; s#^log\.level\s*=.*#log.level = INFO#m' -i .local/etc/softhsm2.conf
```

也可手动编辑 `./.local/etc/softhsm2.conf`：

```ini
# SoftHSM v2 configuration file
directories.tokendir = <repo>/.local/var/lib/softhsm/tokens/
objectstore.backend = db
log.level = INFO
slots.removable = false
```

设置环境变量以显式使用该配置：

```bash
export SOFTHSM2_CONF=$PWD/.local/etc/softhsm2.conf
```

### 5. 初始化与验证

初始化一个 token（非交互）：

```bash
./.local/bin/softhsm2-util --init-token --free --label "My token 1" --so-pin 123456 --pin 123456
```

查看插槽：

```bash
./.local/bin/softhsm2-util --show-slots
```

预期输出包含一个已初始化的 slot，例如：

```text
Available slots:
Slot <number>
    Token info:
        Initialized:      yes
        Label:            My token 1
```

### 6. 常见问题

- Autotools 报错 `/usr/bin/perl5.30: bad interpreter`：可改用 CMake 构建，或修正 Homebrew autotools 的 shebang。
- OpenSSL 为 keg-only：务必通过 `-DOPENSSL_ROOT_DIR=$(brew --prefix openssl@3)` 指定。
- 如需系统范围安装或 p11-kit 集成，请移除 `-DENABLE_P11_KIT=OFF` 并使用具权限的前缀（可能需要 `sudo`）。

### 7. 卸载/清理

本地安装可直接删除目录：

```bash
rm -rf .local build
```

