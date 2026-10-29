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

#include "PluginModuleLoader.hpp"
#include "PluginManager.hpp"

#include <obs-module.h>
#include <util/platform.h>

#include <cstdlib>
#include <string>

/* 构建期由 plugins/ 白名单生成（frontend/cmake/os-android.cmake +
 * frontend/cmake/templates/android-plugin-modules.h.in）。 */
#include <android-plugin-modules.h>

/* Android 上没有"扫描目录找插件"这条路：
 *
 *   - APK 用 extractNativeLibs=false，插件的 .so 不落盘：nativeLibraryDir 是个空目录，
 *     应用自己的库在 /proc/<pid>/maps 里全是 ".../base.apk!/lib/<abi>/" 的 mmap，
 *     libobs 的 find_modules_in_path() 什么都扫不到；
 *   - 唯一可行的是按裸文件名 dlopen —— 调用方所在的 linker namespace 已经包含
 *     base.apk!/lib/<abi>/，所以 obs_open_module("x.so", …) 能命中 APK 内的插件。
 *
 * 所以这里不用 obs_load_plugins()（它内部只做目录扫描），而是按构建期白名单逐个
 * obs_open_module()。白名单与"打进 APK 的插件"是同一个事实的两面，加/减插件只改
 * plugins/CMakeLists.txt 里的一处白名单。
 *
 * data_path 必须是真实目录：obs-module.c 的 obs_open_module() 直接 bstrdup(data_path)
 * 存进 module->data_path，不做 %module% 替换；obs_find_module_file() 只把
 * "<data_path>/<file>" 拼起来 stat()。插件数据由 :/obsplugindata 在启动时解到
 * $OBS_ROOT_PATH/share/obs/obs-plugins/<模块>（见 frontend/utility/AndroidRuntimeBootstrap.cpp）。 */

namespace {

using State = OBS::PluginManager::State;

State loadWhitelistedModules(ModuleList &failedModules)
{
	const char *rootEnv = std::getenv("OBS_ROOT_PATH");
	const std::string dataRoot = std::string(rootEnv ? rootEnv : "") + "/share/obs/obs-plugins/";

	int failures = 0;

	for (const char *const name : OBS_ANDROID_PLUGIN_MODULES) {
		const std::string binary = std::string(name) + ".so";
		const std::string data = dataRoot + name;

		obs_module_t *mod = nullptr;
		const int rc = obs_open_module(&mod, binary.c_str(), data.c_str());
		if (rc != MODULE_SUCCESS) {
			blog(LOG_WARNING, "[android] 装载 %s 失败 rc=%d", binary.c_str(), rc);
			failedModules.emplace_back(name);
			++failures;
			continue;
		}

		if (!obs_init_module(mod)) {
			blog(LOG_WARNING, "[android] %s 的 obs_module_load 返回 false", binary.c_str());
			failedModules.emplace_back(name);
			++failures;
		}
	}

	return failures > 0 ? State::PartialFailure : State::Success;
}

} // namespace

namespace OBS {

State PluginManager::loadPlugins(bool /*usePortableMode*/)
{
	return loadWhitelistedModules(failedModules_);
}

State PluginManager::loadLegacyPlugins(bool /*usePortableMode*/)
{
	/* Android 上没有"旧式插件目录布局"（$HOME/obs-studio/plugins/…），也无需兼容。 */
	return State::Success;
}

} // namespace OBS
