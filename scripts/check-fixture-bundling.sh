#!/bin/sh
# 每個 PluginFixtures/* 目錄都必須列在 project.yml 的 resources,
# 否則 registry 掃不到、外掛靜默消失(V0.2 曾漏 2/12)。缺漏即失敗並點名。
set -eu
cd "$(dirname "$0")/.."

missing=""
for dir in PluginFixtures/*/; do
    name="${dir%/}"
    if ! grep -q "$name" project.yml; then
        missing="$missing $name"
    fi
done

if [ -n "$missing" ]; then
    echo "FAIL: 下列 fixture 未列入 project.yml resources:$missing" >&2
    exit 1
fi
echo "OK: PluginFixtures 全數列於 project.yml ($(ls -d PluginFixtures/*/ | wc -l | tr -d ' ') 項)"
