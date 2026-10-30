# OBS Studio for Android — 移植说明

[![Android compile check](https://github.com/TTTornado/obs-studio-android/actions/workflows/android-compile.yml/badge.svg)](https://github.com/TTTornado/obs-studio-android/actions/workflows/android-compile.yml)

本仓库是 [obsproject/obs-studio](https://github.com/obsproject/obs-studio) 的一个 fork，
在根级布局上叠加 Android 移植（原移植工作由 [cunminF](https://github.com/cunminF/OBS_for_Android) 完成）。
上游基线是 **33.0.0**（`72e8665`），移植改动是叠在它上面的 8 个提交。

```
git log --oneline
  1a2ab29 plugins: Android 分支补 set_obs_core_modules()（33.0 新增机制）
  7d16b16 deps: FFmpeg 7.1.3 -> 8.0.3（OBS 33.0 要求 >= 8.0）
  ...
  3e51aed build: add Android platform build skeleton
  72e8665 CI: Update deps to 2026-10-23 release   ← 33.0.0
```

---

## 版本矩阵

| 组件 | 版本 | 说明 |
|---|---|---|
| OBS 上游基线 | **33.0.0** | `cmake/common/versionconfig.cmake` 需要 |
| Android NDK | **30.0.16138531** | sdkmanager 可装；runner 自带的 `30.0.16248370` 不是同一个 |
| FFmpeg | **8.0.3** | OBS 33.0 要求 ≥ 8.0（32.2.1 时代是 7.1.3） |
| Android SDK | build-tools 36.0.0 / platform android-35 | 与上游脚本一致 |
| 目标 ABI / API | arm64-v8a / API 29 | 只做真机 |
| Qt | **6.9.3**（Android + 桌面） | 与原作者环境一致；Android 套件从 aqt 的 `all_os` 分类装，见下方 |

---

## CI 覆盖什么、不覆盖什么

**覆盖**（`.github/workflows/android-compile.yml`）：

- 14 个第三方依赖的交叉编译（`android/deps-android/`）
- libobs / libobs-opengl(GLES) / 全部 `android-*` 采集插件的**编译与链接**
- 产出 `libobs.so` 与各插件 `.so` 作为 artifact
- **Qt 前端编译**（Qt 6.9.3）与 **APK 打包 + debug 签名**，产出可 sideload 的 APK

**不覆盖**：

- **任何运行时行为**——相机、UVC、MediaProjection、AAudio、推流在 CI 里都验证不了

---

## 本地构建

```bash
# 1) 依赖（产物在 android/deps-android/prebuilt/<abi>/）
bash android/deps-android/fetch.sh
bash android/deps-android/build.sh arm64-v8a

# 2) 编译验证（不需要 Qt）
NDK=$ANDROID_NDK_ROOT bash android/compile-check.sh

# 3) 带前端（需要 Qt for Android + 桌面 Qt）
ENABLE_FRONTEND=ON QT_DIR=~/Qt/6.9.3/android_arm64_v8a \
  QT_HOST_PATH=~/Qt/6.9.3/gcc_64 \
  NDK=$ANDROID_NDK_ROOT bash android/compile-check.sh

# 4) 出可安装的 APK（构建 + androiddeployqt + apksigner）
QT_DIR=~/Qt/6.9.3/android_arm64_v8a \
  QT_HOST_PATH=~/Qt/6.9.3/gcc_64 \
  NDK=$ANDROID_NDK_ROOT ANDROID_SDK_ROOT=$ANDROID_SDK_ROOT \
  bash android/build-apk.sh
# 产物：OBS-Android-arm64-v8a-<mmdd-HHMM>.apk
```

**装 Qt 6.9.3 的命令**（Android 套件不在 `linux_x64/android/`，见下节）：

```bash
pip install aqtinstall
aqt install-qt all_os android 6.9.3 android_arm64_v8a   # Android 套件
aqt install-qt linux desktop 6.9.3 linux_gcc_64         # 桌面宿主（提供 androiddeployqt）
```

`fetch.sh` 的代理是**可选**的：本机开发设 `OBS_PROXY=http://127.0.0.1:7892`，CI 直连留空。

---

## 三个已经踩过的坑（改代码前先读）

### 1. `.gitignore` 的 `/*` 会静默吞掉新文件

`.gitignore` 第 2 行是 `/*`——忽略根下一切，再用逐条 `!` 放行。上游的放行清单里还有两处拼写错误
（`.cirrus.xml` 应为 `.cirrus.yml`、`.git-blame-ignore-devs` 应为 `.git-blame-ignore-revs`）。

**后果**：任何新增的顶层目录/文件，如果没在 `.gitignore` 里加 `!` 放行，`git add` 时会**无声消失**。
本仓库的 `android/` 和 `PORTING.md` 都是靠显式放行才进来的；原移植仓库丢失的 19 个文件也是这个原因。

排查：

```bash
git check-ignore -v <path>   # 打印是哪条规则命中的
```

### 2. CI 里必须显式给 `OBS_VERSION_OVERRIDE`

`cmake/common/versionconfig.cmake:9` 的条件是：

```cmake
if(NOT DEFINED OBS_VERSION_OVERRIDE AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/.git")
```

满足时用 `git describe --always --tags` 推版本。而 `actions/checkout` 默认 `fetch-depth: 1` 且不带 tag，
`describe` 只能返回裸 SHA（如 `54453df`），正则匹配不到 `x.y.z`，于是 `list(GET ...)` 越界、
`project()` 收到非法 VERSION 直接失败。

**修法**：定义 `OBS_VERSION_OVERRIDE`，整段 git 逻辑被跳过。升级基线时要同步改这个值。

### 3. Android 分支提前 `return()` 会跳过上游新增的初始化

`plugins/CMakeLists.txt` 的 Android 白名单在 `:158` 就 `return()`，而上游在文件末尾（`:257`）才调用
`set_obs_core_modules()`。33.0 新增该机制后，Android 路径没生成 `obs-core-modules.c`，导致：

```
CMake Error at libobs/cmake/obs-core-modules.cmake:4 (target_sources):
  Cannot find source file: obs-core-modules.c
```

**修法**：在 `return()` 之前补 `set_obs_core_modules()`（与 `ENABLE_CORE_MODULES=OFF` 分支 `:18` 一致）。

**通用教训**：每次 rebase 上游后，都要检查移植代码里的提前 `return()` / `exit` 是否跳过了上游新增的初始化步骤。

---

## Qt 套件怎么装（6.8+ 的 Android 包在 `all_os` 分类）

**关键事实：Qt 6.8 起，Android 套件不在 `linux_x64/android/` 了。**

| 位置 | 状态 |
|---|---|
| `online/qtsdkrepository/linux_x64/android/` | ❌ 冻结在 **6.7.3**（2024-09-24） |
| `online/qtsdkrepository/all_os/android/` | ✅ 持续更新（6.8 → 6.12） |
| `online/qtsdkrepository/linux_x64/desktop/` | ✅ 仍在更新，桌面套件照旧 |

所以这两条命令的结果完全不同：

```bash
aqt list-qt linux android      → 5.9.0 … 6.7.3    # 看不到 6.8+，会误判"6.9.3 拿不到"
aqt list-qt all_os android     → … 6.9.3 … 6.12    # 真正的位置
```

装法：

```bash
aqt install-qt all_os android 6.9.3 android_arm64_v8a   # Android 套件
aqt install-qt linux desktop 6.9.3 linux_gcc_64         # 桌面宿主（提供 androiddeployqt）
```

aqt 原生支持 `all_os` + `android`（`aqt/metadata.py` 里
`TARGETS_FOR_HOST["all_os"] = ["wasm", "qt", "android"]`），目录名会拼成
`qt6_693/qt6_693_arm64_v8a`，与服务器实际结构一致。

> ⚠️ 早期我曾据此误判"Qt 6.9.3 拿不到"，于是用 6.7.3 试编并为此打了一堆补丁。
> 后来发现包就在 `all_os` 下，已全部切回 6.9.3（见下方"从 6.7.3 切回 6.9.3 撤掉了什么"）。

---

## 从 6.7.3 切回 6.9.3 撤掉了什么

用 6.7.3 期间打的四个补丁，切回 6.9.3 后的处置：

| 补丁 | 处置 | 理由 |
|---|---|---|
| `QT_ANDROID_TARGET_SDK_VERSION` 35 → 34 | ✅ **撤掉，回到 35** | 6.7.3 不支持 edge-to-edge，触摸坐标会整体偏移一个状态栏高度；6.9.3 支持 |
| `android.aapt2FromMavenOverride` | ✅ **撤掉** | 6.7.3 的 AGP 7.4.1 太旧，解析不了新版平台 jar；6.9.3 的 AGP 够新 |
| `InstalledPluginRow.cpp` 的 `QString::fromUtf8` | ✅ **还原成上游写法** | 6.7.3 的 `QString::arg` 没有 `std::string_view` 重载（6.8 才有）；现在该文件与上游 33.0.0 完全一致 |
| 收敛 SDK 平台到 android-35 | ⚠️ **保留** | 纯防御：保证 compileSdk 与 targetSdk 都是 35。若碍事可删 |

代价是前端对 Qt 6.9 的编译期硬依赖只有 1 行（就是上面那条 `QString::arg`），
说明当时用 6.7.3 其实也就差这一点——但**运行时**的 edge-to-edge 差异才是真问题。

---

## APK 打包的坑（Qt 6.7.3 时代踩的，换 6.9.3 后多数已消失）

> 下面两条是**用 Qt 6.7.3 期间**踩的。它的 Gradle 工具链（AGP 7.4.1）太旧，
> 和现代 Android SDK 平台不兼容。换成 Qt 6.9.3 后第 2 条已不需要（补丁已撤），
> 第 1 条保留为防御。记录在此，以防将来又退回 6.7.x。

**1. `androiddeployqt` 自己挑平台，不认 `QT_ANDROID_COMPILE_SDK_VERSION`**

deployment settings 里根本没有 `android-platform` 字段，Qt 扫 SDK 目录自己挑，
而且偏好 `*-ext*` 变体（实测依次挑到 `android-36-ext19` → `android-34-ext12`）。
所以 workflow 里先把 36.x / 35-ext* / 34-ext* 卸掉，只留 `android-35`（= targetSdk）。

**2. AGP 7.4.1 捆绑的 aapt2 读不了新版 `android.jar`**

换哪个平台都报同一句：

```
aapt2 E LoadedArsc.cpp:94] RES_TABLE_TYPE_TYPE entry offsets overlap actual entry data.
aapt2 E ApkAssets.cpp:149] Failed to load resources table in APK '.../android-35/android.jar'
> Task :processReleaseResources FAILED
```

对策（**Qt 6.7.3 专用，现已撤销**）是用 build-tools 里的新版 aapt2 顶替：

```bash
# 若将来又退回 6.7.x，需要重新加这一行
echo "android.aapt2FromMavenOverride=$ANDROID_SDK_ROOT/build-tools/<ver>/aapt2" \
  >> ~/.gradle/gradle.properties
```

**必须写在用户级** `~/.gradle/gradle.properties` —— `androiddeployqt` 每次都会重写
工程级那份，工程级的改动会被覆盖。

**3. 不要删 `android-build` 目录再重打包**

Qt 的 CMake 已经把 `androiddeployqt` 挂成了构建目标（`[450/451] Creating APK for
obs-studio`），但那一刻插件 `.so` 还没暂存，所以那次出的包**不含插件**。
需要重打包一次带上插件；而重打包时 `android-build/libs/<abi>/libobs_arm64_v8a.so`
必须还在，删目录就会报 `Cannot find application binary`。
正确做法：保留目录、只换插件并清 Gradle 的 native 中间件（见 `android/build-apk.sh`）。

---

## 运行时坑：触摸坐标整体偏移（真机实测）

**症状**：APK 装上去能正常启动、界面显示完整，但**大部分控件点不中**，只有在预览区
拖动还能用（因为那块面积大，偏移被"吸收"了）。

**定位过程**（`adb` + 移植自带的 `P8-PRESS` / `P8-REL` 探针）：

```
输入设备坐标 (1315, 395)  ->  P8-PRESS cls=QPushButton win=QMessageBox
                              P8-REL  at=(558,182)
```

`182 × 2.75（dpr）= 500`，而那个按钮在屏幕上**真实位置是 y≈500**。也就是说：
点在 395、Qt 认为是 500 —— **输入坐标被加了约 111 px（= 状态栏高度）的垂直偏移**。

**根因**：窗口属性里是

```
pfl=... EDGE_TO_EDGE_ENFORCED ...
layoutInDisplayCutoutMode=always
InsetsSource type=statusBars frame=[0,0][2400,111]
```

Android 15 对 **targetSdk ≥ 35** 的应用强制 edge-to-edge：应用画到状态栏下面
（内容从 y=0 开始），而 **Qt 6.7.3 不支持 edge-to-edge**，仍按"内容在状态栏下方"
换算输入坐标 ⇒ 绘制与输入差了整整一个状态栏。

原作者用 Qt 6.9.3（支持 edge-to-edge）所以没撞上；我们降到 6.7.3 才暴露。

**当时的权宜之计**：把 `QT_ANDROID_TARGET_SDK_VERSION` 从 35 降到 34 ——
系统不再强制 edge-to-edge，输入与绘制重新对齐（真机验证：设置对话框能正常打开）。

**最终解法**：切回 **Qt 6.9.3**，targetSdk 恢复 **35**。Qt 6.9.3 支持 edge-to-edge，
本来就不需要这个妥协。

> 备选方案（保留 targetSdk 35 且仍用 6.7.3）：在清单 `<application>` 上加
> `android:windowOptOutEdgeToEdgeEnforcement="true"`。但它只是 Android 15 的过渡
> 开关，**Android 16 起失效**，所以没采用。
>
> ⚠️ 若将来又退回 Qt 6.7.x，必须把 targetSdk 改回 34，否则触摸会再次整体偏移。

---

## 待办清单

见下方"移植待办"一节（本文件末尾）。原审查的完整清单在 fork 创建时的会话记录里，
当前优先级：P0 缺陷 → APK 打包 → 真机回归。

### 已完成

- [x] 仓库从"单 squash 快照"改成"以 33.0.0 为父 + 主题提交"
- [x] 同步到上游 33.0.0（472 个上游改动文件，实际冲突 2 个）
- [x] 插件装载重构成上游认可的 `PluginModuleLoader_Android.cpp`
- [x] 补 `obs-core-modules-loader-android.c`（33.0 新增的按平台 loader）
- [x] FFmpeg 7.1.3 → 8.0.3、补 `nlohmann_json` 3.11.3
- [x] CI：依赖编译 + libobs/GLES/插件 编译链接验证
- [x] 4 个 P0：screen 死锁 / 相机旋转 / AAudio 自愈 / screen OOM
- [x] APK 打包 + debug 签名 + artifact（`android/build-apk.sh`）
- [x] 真机首次安装验证（Redmi 23049RAD8C / Android 15）：能启动、界面完整
- [x] 定位并修复"触摸坐标整体偏移"（Android 15 edge-to-edge + Qt 6.7.3）
- [x] 找到 Qt 6.9.3 Android 套件的真实位置（`all_os/android`），切回 6.9.3 并撤掉 4 个妥协补丁

### P0（尚未在真机验证）

- [x] `plugins/android-screen/screen-capture.c` 音频泵死锁（拆 `audio_mx` / `audio_life_mx`）
- [x] `plugins/android-camera/camera2-input.c` sensor orientation（`obs_source_set_async_rotation`）
- [x] `plugins/android-audio/aaudio-input.c` 拔插耳机后永久无声（线程内自愈）
- [x] `plugins/android-screen/screen-capture.c` 全屏 RGBA 的 OOM（`async_unbuffered`）
- [ ] `libobs-opengl/gl-subsystem.c:132` + `gl-shaderparser.c:741` GL 版本门禁矛盾
- [ ] `libobs/obs-android.c:256/327/378/427` 4 张宿主表无原子性/生命周期协议
- [ ] `ObsForegroundService.java` 缺 `microphone` 前台类型（Android 14+ 后台录音静默断）
- [ ] `AndroidManifest.xml:93` `debuggable="true"` + debug keystore 签 release

### 下一步

- [ ] Qt 6.9.3 构建出的 APK 装到真机，确认触摸仍然正常（回归 edge-to-edge）
- [ ] 真机功能回归：启动 → 预览 → 录制 → 摄像头 → 屏幕采集 → 内录 → UVC → 推流
- [ ] 相机画面方向（日志里 `渲染期旋转=N°`）
- [ ] 上面 4 个未修的 P0
