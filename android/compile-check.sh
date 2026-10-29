#!/usr/bin/env bash
# Android 编译验证：配置 + 构建 libobs / GLES 后端 / 全部采集插件。
#
# 默认**不需要 Qt**：frontend/CMakeLists.txt 第 5 行在 find_package(Qt6) 之前
# 就 `if(NOT ENABLE_FRONTEND) return()`，所以 -DENABLE_FRONTEND=OFF 会把整个 Qt
# 前端跳过。因此它可以在任何 Linux（含 GitHub Actions）上跑，用来验证移植的非 UI 部分。
#
# 需要验证前端时设 ENABLE_FRONTEND=ON，并给出 QT_DIR 与 QT_HOST_PATH（见下方环境变量）。
#
# 用法：
#   android/compile-check.sh [构建目录]
#
# 环境变量（均有默认值）：
#   NDK / ANDROID_NDK_ROOT   NDK 根目录（必须存在）
#   ANDROID_SDK_ROOT         Android SDK（可选）
#   DEPS_PREBUILT            依赖 prebuilt 目录，默认 android/deps-android/prebuilt/<abi>
#   ABI                      默认 arm64-v8a
#   API                      默认 29
#   JOBS                     默认 nproc
#   BUILD_TYPE               默认 RelWithDebInfo
#
# 依赖需先准备：
#   android/deps-android/fetch.sh
#   android/deps-android/build.sh arm64-v8a
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ABI="${ABI:-arm64-v8a}"
API="${API:-29}"
JOBS="${JOBS:-$(nproc)}"
BUILD_TYPE="${BUILD_TYPE:-RelWithDebInfo}"
BUILD="${1:-$ROOT/build-android-$ABI}"
NDK="${NDK:-${ANDROID_NDK_ROOT:-}}"
DEPS="${DEPS_PREBUILT:-$ROOT/android/deps-android/prebuilt/$ABI}"

[ -n "$NDK" ] || { echo "FATAL: 未设置 NDK 或 ANDROID_NDK_ROOT" >&2; exit 1; }
[ -d "$NDK" ] || { echo "FATAL: NDK 不存在: $NDK" >&2; exit 1; }
[ -d "$DEPS" ] || {
  echo "FATAL: 依赖 prebuilt 不存在: $DEPS" >&2
  echo "       先运行 android/deps-android/fetch.sh 与 build.sh $ABI" >&2
  exit 1
}

echo "================ Android 编译验证 ================"
echo "ROOT  = $ROOT"
echo "NDK   = $NDK"
echo "DEPS  = $DEPS"
echo "BUILD = $BUILD"
echo "ABI   = $ABI   API=$API   JOBS=$JOBS   TYPE=$BUILD_TYPE"
echo "OBS_VERSION_OVERRIDE = ${OBS_VERSION_OVERRIDE:-(未设置)}"
echo "=================================================="

# OBS 的 CMake 用 `git describe --always --tags` 推版本号
# （cmake/common/versionconfig.cmake:9-24）。CI 里 actions/checkout 默认只取
# 1 个 commit、不带 tag，describe 只能返回裸 SHA（如 54453df），
# 正则匹配不到 x.y.z，于是 list(GET _obs_version_canonical 1 ...) 越界，
# project() 拿到非法 VERSION 直接失败。
#
# versionconfig.cmake:9 的条件是
#   if(NOT DEFINED OBS_VERSION_OVERRIDE AND EXISTS "${...}/.git")
# 所以显式定义 OBS_VERSION_OVERRIDE 会把整段 git 逻辑跳过。
# 升级上游基线时记得同步这个值。
OBS_VERSION_OVERRIDE="${OBS_VERSION_OVERRIDE:-33.0.0}"

EXTRA_SDK=()
if [ -n "${ANDROID_SDK_ROOT:-}" ]; then
  EXTRA_SDK+=("-DANDROID_SDK_ROOT=$ANDROID_SDK_ROOT")
fi

# 前端默认关闭（不需要 Qt）。ENABLE_FRONTEND=ON 时需要：
#   QT_DIR        Qt for Android 套件，如 ~/Qt/6.9.3/android_arm64_v8a
#   QT_HOST_PATH  桌面套件（提供 androiddeployqt），如 ~/Qt/6.9.3/gcc_64
ENABLE_FRONTEND="${ENABLE_FRONTEND:-OFF}"
PREFIX_PATH="$DEPS"
EXTRA_FE=()
if [ "$ENABLE_FRONTEND" = "ON" ]; then
  [ -n "${QT_DIR:-}" ] || { echo "FATAL: ENABLE_FRONTEND=ON 但未设置 QT_DIR" >&2; exit 1; }
  [ -n "${QT_HOST_PATH:-}" ] || { echo "FATAL: ENABLE_FRONTEND=ON 但未设置 QT_HOST_PATH" >&2; exit 1; }
  [ -d "$QT_DIR" ] || { echo "FATAL: QT_DIR 不存在: $QT_DIR" >&2; exit 1; }
  [ -d "$QT_HOST_PATH" ] || { echo "FATAL: QT_HOST_PATH 不存在: $QT_HOST_PATH" >&2; exit 1; }
  PREFIX_PATH="$DEPS;$QT_DIR"
  EXTRA_FE+=("-DQT_HOST_PATH=$QT_HOST_PATH")
  echo "前端 = ON    QT_DIR=$QT_DIR    QT_HOST_PATH=$QT_HOST_PATH"
else
  echo "前端 = OFF（跳过 Qt）"
fi

cmake -S "$ROOT" -B "$BUILD" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI="$ABI" \
  -DANDROID_PLATFORM="android-$API" \
  -DANDROID_STL=c++_shared \
  -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
  -DCMAKE_PREFIX_PATH="$PREFIX_PATH" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DOBS_VERSION_OVERRIDE="$OBS_VERSION_OVERRIDE" \
  -DENABLE_FRONTEND="$ENABLE_FRONTEND" \
  -DENABLE_SCRIPTING=OFF \
  -DENABLE_HEVC=ON \
  "${EXTRA_FE[@]}" \
  "${EXTRA_SDK[@]}" || {
  echo "FATAL: CMake 配置失败" >&2
  exit 1
}

# -k 0：一次跑完所有编译单元，把所有错误一次性报出来（CI 里比默认的快速失败更有用）
cmake --build "$BUILD" -j"$JOBS" -- -k 0
RC=$?

echo "=================================================="
echo "构建退出码 = $RC"
exit $RC
