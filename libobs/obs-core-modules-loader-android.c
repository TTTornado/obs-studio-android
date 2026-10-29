/******************************************************************************
    Copyright (C) 2026 OBS for Android port contributors

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 2 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
******************************************************************************/

#include "obs-core-modules-loader.h"

#include <obs-internal.h>
#include <obs.h>

/* OBS 33.0 把"核心模块"从插件里拆了出来，并且把枚举方式按平台拆成了
 * obs-core-modules-loader-{mac,win,nix}.c。Android 不属于其中任何一个
 * （libobs/CMakeLists.txt 的 PLATFORM_ID 里没有 Android），所以必须在这里
 * 提供 load_core_modules()，否则 obs_load_core_modules() 会 undefined reference。
 *
 * 本移植里没有 obs-modules/core 这套目录布局：APK 用 extractNativeLibs=false，
 * .so 不落盘，任何"按路径枚举模块"的方案都走不通（原因见
 * frontend/plugin-manager/PluginModuleLoader_Android.cpp 的头注释）。
 * 核心模块与普通插件走同一条路 —— 按构建期白名单从 APK 内裸文件名 dlopen。
 *
 * 因此这里不做任何枚举：空实现即代表"没有核心模块装载失败"，
 * obs_load_core_modules() 会据此返回 true，真正的装载交给 loadPlugins()。 */
void load_core_modules(obs_find_module_callback2_t callback, void *data)
{
	(void)callback;
	(void)data;
}
