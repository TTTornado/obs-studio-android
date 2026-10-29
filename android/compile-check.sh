#!/usr/bin/env bash
# Android 编译验证：配置 + 构建 libobs / GLES 后端 / 全部采集插件。
#
# 这个脚本**不需要 Qt**：frontend/CMakeLists.txt 第 5 行在 find_package(Qt6) 之前
# 就 `if(NOT ENABLE_FRONTEND) return()`，所以 -DENABLE_FRONTEND=OFF 会把整个 Qt
# 前端跳过。因此它可以在任何 Linux（含 GitHub Actions）上跑，用来验证移植的非 UI 部分。
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
echo "=================================================="

EXTRA_SDK=()
if [ -n "${ANDROID_SDK_ROOT:-}" ]; then
  EXTRA_SDK+=("-DANDROID_SDK_ROOT=$ANDROID_SDK_ROOT")
fi

cmake -S "$ROOT" -B "$BUILD" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI="$ABI" \
  -DANDROID_PLATFORM="android-$API" \
  -DANDROID_STL=c++_shared \
  -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
  -DCMAKE_PREFIX_PATH="$DEPS" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DENABLE_FRONTEND=OFF \
  -DENABLE_SCRIPTING=OFF \
  -DENABLE_HEVC=ON \
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
