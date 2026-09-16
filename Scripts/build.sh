#!/bin/bash
# MDE Passthrough を建てて実機に入れる。
#
# 使い方:
#   TEAM_ID=XXXXXXXXXX bash Scripts/build.sh                 繋いである実機を自動で探す
#   TEAM_ID=XXXXXXXXXX DEV_ID=<UDID> bash Scripts/build.sh   実機を指定する
#   TEAM_ID=XXXXXXXXXX CLEAN=1 bash Scripts/build.sh         消してから入れ直す
#
# **Mac の GUI セッションの Terminal から走らせること。**
# SSH から叩くと codesign が鍵に届かず、拡張の署名だけが
#   .../MDEPassthroughExtension.debug.dylib: errSecInternalComponent
# で落ちる。コンパイルは通るので out/MDEPassthrough.app は出来上がるが、
# 中の .appex が署名されておらず、install が「not a valid bundle」になる。
# 下の grep に errSec と CodeSign failed を入れてあるのはこのため。
# codesign の失敗行は "error:" の形を取らないので、それだけを見ていると
# 「BUILD FAILED」としか出ずに原因を見失う。
#
# TEAM_ID は Apple Developer の Team ID（10 桁）。project.yml には書いていない。
# ここで渡すか、xcodegen のあと .xcodeproj を Xcode で開いて Team を選ぶ。
# bundle ID（ai.nemut.mdepass / .extension）と App Group も自分のものへ。
set -u
export PATH="/opt/homebrew/bin:$PATH"   # xcodegen
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
LOG="$ROOT/build.log"

APP_ID="ai.nemut.mdepass"
APP_PATH="out/MDEPassthrough.app"

# 実機だけを探す。シミュレータが起きていると devicectl はそれも connected として
# 並べるので、最後の列（Reality）が physical のものに絞る。
# 状態は connected だけではない。USB で繋いでいても "available (paired)" と
# 出ることがあり、それでも install は通る。
find_device() {
  xcrun devicectl list devices 2>/dev/null \
    | awk '$NF == "physical" && (/connected/ || /available/) {
             for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{4}/) { print $i; exit }
           }'
}

# 入れ替えは上書きで行う（CLEAN=1 のときだけ消してから入れる）。
#
# 消してから入れ直すと、拡張が audiomxd に登録した VA port が古いまま残る。
# AudioServerPlugInRegisterMediaDeviceExtension に対になる解除が無く、
# デバイスの UID を固定にしてある（MediaOutputDevice.id と一致させる必要がある）ため、
# 入れ替えのたびに同じ UID の死んだ port が積み上がる。そうなると新しい activate が
# 「もう繋がっている」と判断されて素通りし、誰も IO を出さないまま
# "Unable to Connect" になる。端末の再起動でしか消えない。
#
# 拡張の中身を変えて反映されないときだけ CLEAN=1 を付け、
# そのときは入れ直したあと端末を再起動すること。
install_app() {
  [ -d "$APP_PATH" ] || { echo "!! $APP_PATH が無い"; return 1; }
  [ -n "${DEV_ID:-}" ] || { echo "-- 実機が見つからないので入れない"; return 0; }
  if [ "${CLEAN:-0}" = "1" ]; then
    echo "--- uninstall $APP_ID（このあと端末を再起動すること） ---"
    xcrun devicectl device uninstall app --device "$DEV_ID" "$APP_ID" >/dev/null 2>&1
  fi
  echo "--- install $APP_ID ---"
  xcrun devicectl device install app --device "$DEV_ID" "$APP_PATH" 2>&1 \
    | grep -E "App installed|bundleID|error" | head -5
}

{
  echo "=== start $(date) ==="
  /usr/bin/xcodebuild -version | head -1

  command -v xcodegen >/dev/null 2>&1 || {
    echo "!! xcodegen が無い。brew install xcodegen"
    exit 1
  }
  [ -n "${TEAM_ID:-}" ] || echo "-- TEAM_ID が空。署名の Team は Xcode 側の設定に任せる"

  DEV_ID="${DEV_ID:-$(find_device)}"
  echo "device: ${DEV_ID:-(見つからない)}"

  echo "--- 掃除 ---"
  rm -rf out build MDEPassthrough.xcodeproj

  echo "--- プロジェクトを作る ---"
  xcodegen generate --spec project.yml 2>&1 | tail -5

  echo "================ build MDEPassthrough ================"
  /usr/bin/xcodebuild -project MDEPassthrough.xcodeproj \
    -scheme MDEPassthrough -configuration Debug \
    -sdk iphoneos -arch arm64 -allowProvisioningUpdates \
    ${TEAM_ID:+DEVELOPMENT_TEAM="$TEAM_ID"} \
    CONFIGURATION_BUILD_DIR="$ROOT/out" build 2>&1 \
    | grep -E "error:|errSec|CodeSign failed|BUILD SUCCEEDED|BUILD FAILED|requires a development team|not found and could not|doesn't (support|include)" \
    | tail -25

  echo "--- 成果物 ---"
  ls -d out/*.app 2>&1
  ls -d out/*.app/Extensions/*.appex 2>&1

  install_app

  echo "=== done $(date) ==="
} > "$LOG" 2>&1

echo "FINISHED: $LOG"
