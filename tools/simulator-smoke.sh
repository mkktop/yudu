#!/bin/bash
set -euo pipefail
# 使用 CI 已构建的 App，启动一次完整离线阅读路径并保存截图。
YUDU_APP_PATH="${1:-build/ci/Build/Products/Debug-iphonesimulator/yudu.app}"
YUDU_SHOTS_PATH="${2:-build/simulator-shots}"
YUDU_DEVICE_ID=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; devices=json.load(sys.stdin)["devices"]; print(next(d["udid"] for group in devices.values() for d in group if "iPhone" in d["name"]))')
xcrun simctl boot "$YUDU_DEVICE_ID" || true
xcrun simctl bootstatus "$YUDU_DEVICE_ID" -b
xcrun simctl ui "$YUDU_DEVICE_ID" appearance dark
xcrun simctl install "$YUDU_DEVICE_ID" "$YUDU_APP_PATH"
YUDU_DATA_PATH=$(xcrun simctl get_app_container "$YUDU_DEVICE_ID" com.mkk.yudu data)
swift tools/ReadingFixtures.swift "$YUDU_DATA_PATH/Documents/Fixtures"
xcrun simctl launch "$YUDU_DEVICE_ID" com.mkk.yudu -yuduSelfTest "$YUDU_DATA_PATH/Documents/Fixtures" -yuduOfflineSelfTest
# App 自测顺序完成时会写入 done；最多等 120 秒，失败仍复制诊断文件。
for attempt in $(seq 1 60); do
  if [ -f "$YUDU_DATA_PATH/Documents/selftest/done.txt" ]; then break; fi
  sleep 2
done
mkdir -p "$YUDU_SHOTS_PATH"
cp -R "$YUDU_DATA_PATH/Documents/selftest/." "$YUDU_SHOTS_PATH/"
test "$(cat "$YUDU_SHOTS_PATH/done.txt")" = "OK"
test -s "$YUDU_SHOTS_PATH/01-bookshelf.jpg"
test -s "$YUDU_SHOTS_PATH/03-reader-page1.jpg"
test -s "$YUDU_SHOTS_PATH/08-settings.jpg"
xcrun simctl terminate "$YUDU_DEVICE_ID" com.mkk.yudu
printf 'Simulator reading smoke test passed.\n'
