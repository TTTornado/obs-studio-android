# OBS Studio for Android — 移植说明

[![Android compile check](https://github.com/TTTornado/obs-studio-android/actions/workflows/android-compile.yml/badge.svg)](https://github.com/TTTornado/obs-studio-android/actions/workflows/android-compile.yml)

本仓库是 [obsproject/obs-studio](https://github.com/obsproject/obs-studio) 的一个 fork，
在根级布局上叠加 Android 移植（原移植工作由 [cunminF](https://github.com/cunminF/OBS_for_Android) 完成）。
上游基线是 **33.0.0**（`72e8665`），移植改动是叠在它上面的 32 个提交
（`git log --oneline 33.0.0..HEAD` 看全量）。近期主线：

```
1f7963f frontend: 首页布局与工具栏尺寸（按内容推导，修掉裁切）
b6833e0 frontend: 对话框尺寸与单指滚动（源码级放宽 + clamp 只缩放）
fcc7a4e fix: 整体审查后的 P0（5 处会崩/UAF + 4 处 clamp 回归 + 1 处性能）
613f977 ci: test/** 分支也自动构建
f76a9a8 frontend: 对话框装不下时清掉窗口最小尺寸并关掉布局反推
...
72e8665 CI: Update deps to 2026-10-23 release   ← 33.0.0
```

---

## 版本矩阵

| 组件 | 版本 | 说明 |
|---|---|---|
| OBS 上游基线 | **33.0.0** | `cmake/common/versionconfig.cmake` 需要 |
| Android NDK | **30.0.16138531** | sdkmanager 可装；runner 自带的 `30.0.16248370` 不是同一个 |
| FFmpeg | **8.0.3** | OBS 33.0 要求 ≥ 8.0（32.2.1 时代是 7.1.3） |
| Android SDK | platform android-35 | build-tools 用 runner 自带的最新版（未钉版本） |
| 目标 ABI / API | arm64-v8a / API 29 | 只做真机 |
| Qt | **6.9.3**（Android + 桌面） | 与原作者环境一致；Android 套件从 aqt 的 `all_os` 分类装，见下方 |

---

## CI 覆盖什么、不覆盖什么

**覆盖**（`.github/workflows/android-compile.yml`）：

- 15 个第三方依赖的交叉编译（`android/deps-android/`）
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

## 对话框装不下屏幕：从"硬压窗口"到"源码级放宽"

手机横屏的逻辑尺寸只有 **873×393**，而 OBS 的对话框是按桌面设计的：

| 对话框 | 设计尺寸 | 症状 |
|---|---|---|
| 添加源 | 1040×620 | 宽高超屏，底部按钮和右侧内容都在屏外 |
| 设置 | 981×730，`.ui` 写死 `minimumSize 700×512` | 被锁在 512 高，底部按钮整行看不见 |
| 高级音频 | 1100×340 | 宽超屏 |

### 走过的弯路（别重复）

第一版是在 `AndroidInputFilter` 的 Show 分支做**全局兜底**：任何顶层窗口超过
`screen()->availableGeometry()` 就 `resize` 到可用区并居中。结果一路补了五层：

1. `resize` + 居中 —— 不动子控件，压不下去
2. 把内部 `QAbstractScrollArea` 的 `minimumHeight` 压到 64 —— 还是不动
3. 清窗口自己的 `setMinimumSize(0,0)` —— `activate()` 又把它设回来
4. `layout()->setSizeConstraint(SetNoConstraint)` —— 终于能压了
5. 改子控件 `sizePolicy` —— 事后证明多余

**第 4 层是错的**：它造出"窗口比内容小"的不一致状态 —— 窗口压到 377，而布局仍按
478 摆放子控件，添加源左侧列表被摆成 460 高、裁在 377 的窗口里，
**viewport 比可视区大 ⇒ 滚动条范围算错，列表既不能滚、命中判定也错位**。

### 正确做法：各对话框自己解除桌面尺寸限制

`clampTopLevelToScreen` 现在只做 `resize` + 居中，**不碰任何约束**；被挡住时只打一条
`CLAMP-BLOCKED` 日志，作为"还有哪些对话框没做源码级修复"的待办清单。

**添加源**（`OBSBasicSourceSelect.cpp`）—— 两行缺一不可：

```cpp
ui->sourceTypeList->setMinimumHeight(0);
ui->sourceTypeList->setSizeAdjustPolicy(QAbstractScrollArea::AdjustIgnored);
```

它们堵的是两条不同的路。`QLayout` 算最小尺寸走 `qSmartMinSize()`
（`qlayoutengine.cpp:321-333`）：

```cpp
s = max(sizeHint, minimumSizeHint);      // sizePolicy 无 ShrinkFlag 时
if (minSize.height() > 0) s = minSize;   // 非零则无条件覆盖
```

| 只做哪一行 | 460 从哪条路回来 | 布局最小高 |
|---|---|---|
| `setMinimumHeight(0)` | `sizeHint()`（`.ui` 把策略设成 `AdjustToContents`，跟随内容） | 460 ❌ |
| `setSizeAdjustPolicy(AdjustIgnored)` | `minSize`（`.ui` 的 `0x460`，非零时无条件覆盖） | 460 ❌ |
| **两行都有** | — | **~192** ✅ |

> ⚠️ `AdjustIgnored` **不是**"Qt 默认值所以可删"：`OBSBasicSourceSelect.ui:160-162`
> 显式把策略设成了 `AdjustToContents`。两种策略下 `sizeHint()` 行为完全不同
> （`qabstractscrollarea.cpp:1426-1442`）：
> `AdjustIgnored` → 固定 `256×192`；`AdjustToContents` → `frame + scrollbars + viewportSizeHint()`。

**设置**（`OBSBasicSettings.cpp`）—— 内容本来装得下（每页自带 `QScrollArea`，
实测布局最小高 330），只是 `.ui` 写死的 `minimumSize 700×512` 锁住了，`setMinimumSize(0,0)` 即可。

真机验证（两个对话框都**一次 resize 成功**，无 `CLAMP-BLOCKED`）：

```
CLAMP OBSBasicSourceSelect 1040x620 -> 目标 857x377 实际 857x377（可用 873x393）
CLAMP OBSBasicSettings     981x375 -> 目标 857x375 实际 857x375（可用 873x393）
```

---

## 单指滚动：QScroller 与 item view 的取舍

Qt 在 Android 上把单指触摸合成成鼠标事件，而 `QAbstractScrollArea` 只在 `wheelEvent`
里滚动 —— 所以默认只有**双指拖**（Qt 合成成 `QWheelEvent`）能滚。

`enableFlickScroll()` 在顶层窗口 Show 后给里面的滚动区挂 `QScroller`，按控件类型分开：

| 控件类型 | 手势模式 | 实测 |
|---|---|---|
| `QScrollArea`（设置页） | `TouchGesture` | ✅ 正常 |
| `QAbstractItemView`（QListWidget/QTreeView） | `LeftMouseButtonGesture` | ✅ 能滚，但**按下那一项会被选中一次** |

`QAbstractItemView` 上用 `TouchGesture` **不生效**：它自己处理触摸，识别器抢不到，
事件退回成"按住左键拖选"。添加源列表因此不滚，而且 `currentItemChanged` 接到了
`sourceTypeSelected`，拖选每改一次当前项右边面板就刷一次，看起来像"依次点开所有项"。

改用 `LeftMouseButtonGesture` 后 QScroller 会抓走鼠标并消费移动事件，拖动变滚动。
**已知代价**：按下位置那一项仍会被选中一次（按下先到控件，QScroller 要超过阈值才接管）。
在设置对话框左栏拖动也会切一次页 —— 对导航列表可以接受。

> 试过"自己实现拖动滚动"（吃掉移动事件、直接改滚动条数值）：功能正确但不优雅 ——
> 绕过 Qt 的机制、放弃惯性、还要为一个个案在全局输入层加逻辑。已回退。

---

## 首页布局：从魔数到推导

dock 比例原本写死在 `OBSInit()` 里（`30%` / `20%` / `51:16:33`），现在提取成
`OBSBasic::ResizeAndroidDocks()`（`OBSBasic_Docks.cpp`），`OBSInit` 和
`on_resetDocks_triggered` 共用 —— 否则"重置界面"之后不会再套用。

比例改成按内容推导：

```cpp
const int toolbarWidth = qMax(ui->scenesToolbar->sizeHint().width(), ...);
const int side   = qMax(toolbarWidth + 8, width() * 28 / 100);   // 左栏至少装得下工具栏
const int bottom = qMax(mixer/transitions/controls 的 minimumSizeHint().height());
```

工具栏按钮尺寸也改成从 `ui->transitionAdd->sizeHint()` / `iconSize()` 推导，再用 QSS
精确控制（`border/padding` 归零，让 `min/max` 就是外尺寸），`QToolBar` 一起撑到
`buttonSize.height()+2` 覆盖主题给的 32px 上限 —— **之前按钮设了 48×48 下限但工具栏
高度不够，图标就被裁**。溢出按钮（`">>"`）不动：给它加尺寸会让 Qt 在算溢出时多留宽度，
把后面的动作全收进菜单。

列表行高也归位了：场景列表的 `min-height` 从 `OBSInit` 里的一次性样式表挪进
`SceneTree::SetGridMode()`（顺手修掉"切一次网格模式样式表就被覆盖"的隐患）；
源列表在 `SourceTreeDelegate::sizeHint()` 里夹（样式表盖不过 delegate 返回的行高）。

真机结果：

```
Android toolbar: scenes=5 sources=5 button=26x28 rows=34/-1
Android layout: side=244 bottom=135 preview=648x162
```

5 个工具栏按钮全部完整可见、不再裁切。

---

## 待办清单

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
- [x] 全量代码审查（4 区域并行）+ 5 处会崩/UAF 修复：nikon 解码缓冲、camera2 id 越界、
      uvc 取消后释放、`obs-android` 四张宿主表原子化、`OBSBasic_Transitions` 跨平台 ifdef
- [x] `gl-android.c` 补 `eglSwapInterval(display, 0)`（桌面两个 EGL 后端都设了，Android 漏了）
- [x] 对话框装不下屏幕：改成源码级放宽最小尺寸，clamp 只缩放不碰约束
- [x] 单指滚动：`QScrollArea` 用 `TouchGesture`、`QAbstractItemView` 用 `LeftMouseButtonGesture`
- [x] 首页布局与工具栏尺寸：从魔数改成按内容推导，修掉按钮裁切

### 待办

**已知缺陷**

- [ ] **浮动 dock 崩溃**：有源在渲染时浮动 dock → 新原生窗口销毁 Surface →
      `makeCurrent(): no EGLSurface` → `QRhiGles2` 失败 → SIGSEGV
      （`reason=5 (APP CRASH(NATIVE))` status=11）。倾向方案：Android 上直接去掉
      `DockWidgetFloatable`，一并解决"浮动后找不回"
- [ ] **嵌套子菜单坐标错位**：`视图 → 打开多视图 → 显示器 1` 点不动。Qt 报的子菜单几何
      （`geo=692x334+163+59`）与实际绘制位置不符，点击落到父菜单。影响所有二级菜单
      （场景列表模式 / 统计 等）；`frontend/utility/AndroidMenuPos.hpp` 只覆盖了部分场景
- [ ] **剩余 `CLAMP-BLOCKED` 对话框**（属性 720×580 / 高级音频 1100×340 / 变换 900×280 /
      关于 840×519 / 更新 611×526 …）逐个做源码级放宽。
      做法：跑一遍主界面打开各个对话框，日志里每一条 `CLAMP-BLOCKED` 就是一个待修项
- [ ] `ObsForegroundService.java` 缺 `microphone` 前台类型（Android 14+ 后台录音静默断）
- [ ] `AndroidManifest.xml:93` `debuggable="true"` + debug keystore 签 release

**未做真机功能验证**

- [ ] UVC / Camera2 / 尼康 三条采集路径 —— P0 改了它们的解码缓冲、id 拷贝、传输释放，
      只做过编译验证，需要各跑一次确认没坏
- [ ] 录制 / 推流 / 屏幕采集 / 系统内录 / 相机方向（日志里 `渲染期旋转=N°`）

**工程债**

- [ ] `AndroidInputFilter`（`OBSApp.cpp`，约 500 行含 170 行注释、11 个 case）承担 5 件
      互不相关的事：长按=右键、BACK=Escape、组合框弹层补丁(P-8)、clamp、QScroller 挂载。
      建议拆成 4 个单责过滤器
- [ ] 探针日志 63 处：约 20 处有长期价值、约 21 处是每事件残留。建议加
      `OBS_ANDROID_PROBE` 运行时开关（默认关），长期项降到 `LOG_DEBUG`
- [ ] 提取 `plugins/android-common/`：uvc 与 nikon 有 6 组逐字重复（USB 枚举、采集线程
      三件套、JPEG→BGRA 整段…）。**复制已经造成过缺陷** —— nikon 漏了 uvc 已修好的 NULL 检查
- [ ] 容器格式限制 5 处各自编码、预览面所有权 5 处各自实现 —— 收敛成单一入口
- [ ] CI：缓存 key 不含 `NDK_VERSION`/`API`；`always()` 保存半成品 prebuilt 可能毒化缓存；
      paths 漏了 `deps/**`；`.gitignore` 对 `android/deps-android/{prebuilt,src}` 无规则
- [ ] 构建可重现性：x264/rnnoise 钉的是 `master` 分支且无 checksum；每次构建新生成 keystore；
      `apksigner`/`aapt2` 用 `sort -V | tail -1` 取最新
