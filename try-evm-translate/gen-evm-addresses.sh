#!/bin/bash
# 批量生成 EVM 地址
# 用法: bash gen-evm-addresses.sh <数量> <label前缀> <起始id>
# 示例: bash gen-evm-addresses.sh 10 user- 1

set -e

# 设置路径
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)

# 检查参数
if [ $# -lt 3 ]; then
    echo "用法: $0 <数量> <label前缀> <起始id>"
    echo "示例: $0 10 user- 1"
    exit 1
fi

COUNT=$1
LABEL_PREFIX=$2
START_ID=$3

# 检查环境变量
if [ -z "$SOFTHSM2_CONF" ]; then
    echo "SOFTHSM2_CONF 环境变量未设置"
    exit 1
fi

if [ -z "$USER_PIN" ]; then
    echo "USER_PIN 环境变量未设置"
    exit 1
fi

# 获取模块路径
MODULE="$REPO_DIR/.local/lib/softhsm/libsofthsm2.dylib"

if [ ! -f "$MODULE" ]; then
    echo "找不到模块: $MODULE"
    exit 1
fi

echo "使用模块: $MODULE"
echo "生成 $COUNT 个地址，label前缀: $LABEL_PREFIX，起始id: $START_ID"

# 创建输出目录
mkdir -p pubkeys
rm -f evm-addresses.csv
echo "label,id,address,address_eip55" > evm-addresses.csv

# Python 辅助函数
PY_HELPER=$(cat <<'PY'
import sys
import os
sys.path.insert(0, os.path.abspath(sys.argv[1])) # REPO_DIR
from pkcs11_walletkit.evm import generate_address

module_path = sys.argv[2]
user_pin = sys.argv[3]
key_id = sys.argv[4]
label = sys.argv[5]

try:
    addr, addr55, spki = generate_address(module_path, user_pin, key_id, label)
    print(f"{addr} {addr55}")
    # 保存公钥
    with open(f"pubkeys/{label}-pub.der", "wb") as f:
        f.write(spki)
except Exception as e:
    print(f"ERROR: {e}")
    sys.exit(1)
PY
)

# 批量生成
for i in $(seq $START_ID $((START_ID + COUNT - 1))); do
    id=$(printf "%04d" $i)
    label="${LABEL_PREFIX}${id}"
    
    echo "生成 $label (id=$id)..."
    
    # 调用 Python 生成地址
    read addr addr55 < <(python3 -c "$PY_HELPER" "$REPO_DIR" "$MODULE" "$USER_PIN" "$id" "$label")
    
    if [ $? -eq 0 ] && [ -n "$addr" ] && [ -n "$addr55" ]; then
        echo "$label,$id,$addr,$addr55" >> evm-addresses.csv
        echo "  -> $addr55"
    else
        echo "  -> 失败"
    fi
done

echo "完成！生成 $COUNT 个地址"
echo "结果保存在 evm-addresses.csv"
echo "公钥保存在 pubkeys/ 目录"

