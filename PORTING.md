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
| Qt | 目标 6.9.3 / CI 试编 6.7.3 | 见下方"Qt 的坑" |

---

## CI 覆盖什么、不覆盖什么

**覆盖**（`.github/workflows/android-compile.yml`）：

- 14 个第三方依赖的交叉编译（`android/deps-android/`）
- libobs / libobs-opengl(GLES) / 全部 `android-*` 采集插件的**编译与链接**
- 产出 `libobs.so` 与各插件 `.so` 作为 artifact

**不覆盖**：

- Qt 前端（另有一个 `continue-on-error` 的前端 job 在做探索）
- APK 打包与签名
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

## Qt 的坑（前端 CI 的前置）

Qt 官方公开镜像上，**Android 套件最新只到 6.7.3**：

```
aqt list-qt linux android          → 5.9.0 … 6.7.3      （没有 6.8/6.9）
aqt list-qt linux desktop --arch 6.9.3 → linux_gcc_64   （桌面版有 6.9.3）
```

而本移植的目标是 Qt 6.9.3。所以前端 CI 目前在用 **6.7.3 试编**，目的是搞清楚 33.0 前端到底依赖哪些
6.9 特性；如果 6.7.3 编不过且差异很大，再考虑用 Qt 账号 + secret 走官方安装器。

---

## 待办清单

见下方"移植待办"一节（本文件末尾）。原审查的完整清单在 fork 创建时的会话记录里，
当前优先级：P0 缺陷 → APK 打包 → 真机回归。

### 已完成

- [x] 仓库从"单 squash 快照"改成"以 33.0.0 为父 + 主题提交"
- [x] 同步到上游 33.0.0（472 个上游改动文件，实际冲突 2 个）
- [x] 插件装载重构成上游认可的 `PluginModuleLoader_Android.cpp`
- [x] 补 `obs-core-modules-loader-android.c`（33.0 新增的按平台 loader）
- [x] FFmpeg 7.1.3 → 8.0.3
- [x] CI：依赖编译 + libobs/GLES/插件 编译链接验证

### P0（真机必然撞到）

- [ ] `plugins/android-screen/screen-capture.c:404-408` 音频泵死锁
- [ ] `plugins/android-camera/camera2-input.c:306,1246` sensor orientation 未旋转（预览横躺 90°）
- [ ] `plugins/android-audio/aaudio-input.c:455-461` 拔插耳机后永久无声
- [ ] `plugins/android-screen/screen-capture.c:529` 全屏 RGBA 不缩放（约 300MB，OOM）
- [ ] `libobs-opengl/gl-subsystem.c:132` + `gl-shaderparser.c:741` GL 版本门禁矛盾
- [ ] `libobs/obs-android.c:256/327/378/427` 4 张宿主表无原子性/生命周期协议
- [ ] `ObsForegroundService.java` 缺 `microphone` 前台类型（Android 14+ 后台录音静默断）
- [ ] `AndroidManifest.xml:93` `debuggable="true"` + debug keystore 签 release

### 下一步

- [ ] 前端 CI（Qt 6.7.3 试编）跑通或得出结论
- [ ] APK 打包 + 签名 + artifact
- [ ] 真机回归：启动 → 预览 → 录制 → 摄像头 → 屏幕采集 → 内录 → UVC → 推流
