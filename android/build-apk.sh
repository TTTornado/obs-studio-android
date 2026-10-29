#!/usr/bin/env bash
# 打一个可安装的 arm64-v8a APK（需要 Qt for Android + 桌面 Qt）。
#
# 用法：
#   QT_DIR=~/Qt/6.9.3/android_arm64_v8a \
#   QT_HOST_PATH=~/Qt/6.9.3/gcc_64 \
#   NDK=$ANDROID_NDK_ROOT \
#   android/build-apk.sh
#
# 环境变量：
#   QT_DIR         Qt for Android 套件（必须）
#   QT_HOST_PATH   桌面套件，提供 bin/androiddeployqt（必须）
#   ANDROID_SDK_ROOT（必须，apksigner / aapt2 在里面）
#   NDK / ANDROID_NDK_ROOT（必须）
#   KEYSTORE       签名用 keystore；缺省则自动生成一个 debug keystore
#   DEPS_PREBUILT  依赖 prebuilt 目录，默认 android/deps-android/prebuilt/<abi>
#   ABI / API / JOBS / BUILD_DIR 同 compile-check.sh
#
# 产物：$ROOT/OBS-Android-<abi>-<timestamp>.apk
#
# 与 android/compile-check.sh 的分工：那个只验证"能编"，本脚本负责"能装"。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ABI="${ABI:-arm64-v8a}"
API="${API:-29}"
JOBS="${JOBS:-$(nproc)}"
BUILD="${BUILD_DIR:-$ROOT/build-android-apk-$ABI}"
NDK="${NDK:-${ANDROID_NDK_ROOT:-}}"
DEPS="${DEPS_PREBUILT:-$ROOT/android/deps-android/prebuilt/$ABI}"
QT_DIR="${QT_DIR:-}"
QT_HOST_PATH="${QT_HOST_PATH:-}"
SDK="${ANDROID_SDK_ROOT:-}"

die() { echo "FATAL: $*" >&2; exit 1; }

[ -n "$NDK" ] || die "未设置 NDK / ANDROID_NDK_ROOT"
[ -d "$NDK" ] || die "NDK 不存在: $NDK"
[ -n "$QT_DIR" ] || die "未设置 QT_DIR（Qt for Android 套件）"
[ -d "$QT_DIR" ] || die "QT_DIR 不存在: $QT_DIR"
[ -n "$QT_HOST_PATH" ] || die "未设置 QT_HOST_PATH（桌面套件）"
[ -x "$QT_HOST_PATH/bin/androiddeployqt" ] || die "找不到 $QT_HOST_PATH/bin/androiddeployqt"
[ -n "$SDK" ] || die "未设置 ANDROID_SDK_ROOT"
[ -d "$DEPS" ] || die "依赖 prebuilt 不存在: $DEPS"

echo "================ 打 APK ================"
echo "ROOT   = $ROOT"
echo "NDK    = $NDK"
echo "QT_DIR = $QT_DIR"
echo "QT_HOST= $QT_HOST_PATH"
echo "SDK    = $SDK"
echo "BUILD  = $BUILD"
echo "ABI    = $ABI  API=$API  JOBS=$JOBS"
echo "========================================"

# ---------------------------------------------------------------- 1) 构建
# 复用 compile-check.sh：它已经处理了 OBS_VERSION_OVERRIDE、CMake 参数、Qt 路径。
ENABLE_FRONTEND=ON \
QT_DIR="$QT_DIR" \
QT_HOST_PATH="$QT_HOST_PATH" \
NDK="$NDK" \
DEPS_PREBUILT="$DEPS" \
ABI="$ABI" API="$API" JOBS="$JOBS" \
	bash "$ROOT/android/compile-check.sh" "$BUILD" || die "前端构建失败"

FE="$BUILD/frontend"
[ -d "$FE" ] || die "构建目录里没有 frontend/: $FE"

# ---------------------------------------------------------------- 2) 插件 .so 暂存
# 插件名不以 lib 开头，走不了 QT_ANDROID_EXTRA_LIBS（androiddeployqt 硬性要求 lib 前缀），
# 只能放进包源目录的 libs/<abi>/，由 gradle 当 jniLibs 收进 APK。
#
# 注意：**先清空再拷**。原来只做 cp -f，删掉的插件会一直留在包里、
# 旧 .so 会覆盖新构建 —— 那种"改了没生效"最难查。
PLUG_SRC="$(find "$BUILD/rundir" -type d -path '*/lib/obs-plugins' 2>/dev/null | head -1)"
[ -n "$PLUG_SRC" ] || die "rundir 里找不到 lib/obs-plugins（APK 会缺插件）"

PKG_LIBS="$ROOT/frontend/cmake/android/libs/$ABI"
rm -rf "$PKG_LIBS"
mkdir -p "$PKG_LIBS"
cp -f "$PLUG_SRC"/*.so "$PKG_LIBS"/
echo "---- 插件暂存 -> frontend/cmake/android/libs/$ABI ----"
ls -1 "$PKG_LIBS" | sed 's/^/  /'

# ---------------------------------------------------------------- 3) 带插件重打包
SETTINGS="$FE/android-obs-studio-deployment-settings.json"
[ -f "$SETTINGS" ] || die "找不到 deployment settings: $SETTINGS"

AB="$FE/android-build"
[ -d "$AB" ] || die "构建没有生成 android-build: $AB"

# 注意：**不要**删掉 android-build 目录。
# Qt 的 CMake 已经把 androiddeployqt 挂成构建目标（日志里的
# "[450/451] Creating APK for obs-studio"），那次出包时插件还没暂存，
# 所以那个 APK **不含插件**；而 androiddeployqt 重跑时需要
# android-build/libs/<abi>/libobs_arm64_v8a.so（CMake 拷进去的应用库），
# 目录一删就会报 "Cannot find application binary"。
# 因此这里只做"换掉插件 + 清产物"，然后强制重打包 —— 与原移植脚本同一套路。
mkdir -p "$AB/libs/$ABI"
cp -f "$PLUG_SRC"/*.so "$AB/libs/$ABI"/
rm -f "$AB/obs-studio.apk"
rm -rf "$AB/build/outputs/apk" \
	"$AB/build/intermediates/merged_jni_libs" \
	"$AB/build/intermediates/merged_native_libs" \
	"$AB/build/intermediates/stripped_native_libs"
find "$AB/build/outputs" -name '*-signed*.apk' -delete 2>/dev/null || true

echo "---- androiddeployqt（带插件重打包） ----"
( cd "$FE" && "$QT_HOST_PATH/bin/androiddeployqt" \
	--input "$SETTINGS" \
	--output "$AB" \
	--apk "$AB/obs-studio.apk" \
	--depfile "$AB/obs-studio.d" \
	--builddir "$FE" \
	--release ) || die "androiddeployqt 失败（看上面日志里的 BUILD FAILED / error:）"

# ---------------------------------------------------------------- 4) 签名
APK="$(find "$AB/build/outputs/apk" -name '*.apk' ! -name '*-signed*' 2>/dev/null | head -1)"
[ -n "$APK" ] || die "androiddeployqt 没产出 APK（找 $AB/build/outputs/apk）"

KS="${KEYSTORE:-}"
if [ -z "$KS" ]; then
	KS="$BUILD/debug.keystore"
	if [ ! -f "$KS" ]; then
		echo "---- 生成 debug keystore ----"
		keytool -genkeypair -v -keystore "$KS" -alias androiddebugkey \
			-storepass android -keypass android -keyalg RSA -keysize 2048 -validity 10000 \
			-dname "CN=Android Debug,O=Android,C=US" >/dev/null 2>&1 ||
			die "keytool 生成 keystore 失败（JAVA_HOME 指向 JDK 17？）"
	fi
fi

APKSIGNER="$(ls "$SDK"/build-tools/*/apksigner 2>/dev/null | sort -V | tail -1)"
[ -n "$APKSIGNER" ] || die "找不到 apksigner（$SDK/build-tools/*/apksigner）"
echo "---- 签名（$APKSIGNER） ----"

SIGNED="${APK%.apk}-signed.apk"
cp -f "$APK" "$SIGNED"
"$APKSIGNER" sign --ks "$KS" --ks-key-alias androiddebugkey \
	--ks-pass pass:android --key-pass pass:android --out "$SIGNED" "$SIGNED" ||
	die "apksigner sign 失败"
"$APKSIGNER" verify "$SIGNED" || die "apksigner verify 失败"

# ---------------------------------------------------------------- 5) 归档 + 自检
STAMP="$(date '+%m%d-%H%M')"
OUT="$ROOT/OBS-Android-$ABI-$STAMP.apk"
cp -f "$SIGNED" "$OUT"

AAPT2="$(ls "$SDK"/build-tools/*/aapt2 2>/dev/null | sort -V | tail -1)"
echo "================ 结果 ================"
ls -la "$OUT"
if [ -n "$AAPT2" ]; then
	echo "---- badging ----"
	"$AAPT2" dump badging "$OUT" 2>/dev/null |
		grep -E '^package:|application-label:|native-code|sdkVersion|targetSdkVersion' | sed 's/^/  /'
fi

echo "---- APK 内 native 库（$ABI）----"
unzip -l "$OUT" 2>/dev/null | grep "lib/$ABI/" | awk '{print "  " $1 "  " $4}'

# 从 APK 里把**应用库**掏出来查 .dynsym 的 main：
# 这是 APK 能被 dlopen 起来的前提，原移植脚本里也有这一步，这里自动化。
# 注意两个名字别搞混：
#   libobs_<abi>.so  —— Qt 打包的应用库（本文件，含 main）
#   liblibobs.so     —— libobs 本体（经 QT_ANDROID_EXTRA_LIBS 进来，被加了 lib 前缀）
APP_LIB="lib/$ABI/libobs_${ABI}.so"
CHK="$BUILD/apkcheck"
rm -rf "$CHK"
mkdir -p "$CHK"
if unzip -o -q "$OUT" "$APP_LIB" -d "$CHK" 2>/dev/null; then
	echo "---- APK 内应用库 $APP_LIB 的 main 动态符号 ----"
	if "$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf" --dyn-syms \
		"$CHK/$APP_LIB" 2>/dev/null | grep -qw main; then
		echo "  OK：.dynsym 里有 main"
	else
		echo "  !! .dynsym 里没有 main —— APK 装得上但起不来"
	fi
else
	echo "  !! APK 里没有 $APP_LIB"
fi
echo "======================================"
echo "APK: $OUT"
