# 图标包管理器 (Icon Pack Manager)

适用于 KOReader 的图标包切换插件，支持管理以下图标：

- **KOReader 官方图标**（通过 `<数据目录>/icons` 用户覆盖机制，完美适配安卓与电子墨水屏设备）
- **Simple UI 插件图标**（`plugins/simpleui.koplugin/icons`，**可选**，未安装时自动跳过）

---

## 特性

* **全平台原生适配（完美支持安卓）**：在 Android 设备上，KOReader 程序位于应用私有目录，而数据位于 `/sdcard/koreader`。本插件采用 KOReader 官方推荐的用户覆盖路径 `<数据目录>/icons`，不破坏程序本体文件，即使 OTA 升级或覆盖安装也不会丢失图标，也彻底解决了安卓上的只读/权限问题。
* **内置官方图标包，免去繁琐备份**：插件直接内置了 KOReader 官方最新 `mdlight` 图标与 Simple UI 官方图标。安装后**无需执行备份**即可直接一键更换主题；随时点击“恢复官方默认图标”即可秒级复原。
* **双向兼容 Simple UI**：自动探测 Simple UI 插件（支持安卓用户存储及各平台安装目录）。安装了则协同更换，未安装则自动仅管理 KOReader 图标。
* **智能格式识别**：支持多主题平铺文件夹、嵌套版本子文件夹，以及结构化 ZIP 压缩包。
* **完整性检测报告**：直观查看每个图标包的覆盖率、缺失的原版图标列表及未知 SVG。
* **原子级安全切换**：每次更换基于官方基准叠加，异常自动秒级回滚。

---

## 安装与使用

1. 将 `iconpackmanager.koplugin` 文件夹整体放入 KOReader 的 `plugins/` 目录并重启 KOReader。
   - **Android**: `/sdcard/koreader/plugins/iconpackmanager.koplugin`
   - **Kindle**: `/koreader/plugins/iconpackmanager.koplugin`
   - **Kobo**: `/.adds/koreader/plugins/iconpackmanager.koplugin`
2. 打开“工具 -> 图标包管理器”。
3. 点击“**图标包文件夹**”选择保存主题文件夹或 ZIP 的目录（例如新建一个 `/sdcard/koreader/iconpacks` 或放在外部存储中）。
4. 可先打开“**图标完整性检测**”，查看每个主题的图标覆盖情况。
5. 打开“**扫描到的图标包**”，选择一个主题并确认“**一键更换**”。
6. 按提示重启 KOReader 即可生效。
7. 如需还原，随时点击“**恢复官方默认图标**”并重启。

---

## 图标包支持格式

### 1. 文件夹格式

插件会将所选目录下的每个子文件夹识别为一个主题。常规平铺图标包可直接使用：

```text
图标包/
├── 动物森林/
│   ├── appbar.menu.svg
│   └── settings.svg
└── 黑猫/
    ├── appbar.menu.svg
    └── plugins/
        └── frontlight.svg
```

* 平铺文件会按文件名与 KOReader（以及 Simple UI）图标匹配；同名图标在两个目标中都存在时会同时替换。
* 无法匹配的 SVG 会在检测报告中列出，但不会被错误安装。
* 若一个主题目录下没有直接放 SVG，而是包含多个子风格（如 `暗色/`、`亮色/`），每个子目录会被自动识别为独立图标包。

### 2. ZIP 格式

推荐结构：

```text
my-icons.zip
├── mdlight/
│   ├── appbar.menu.svg
│   └── settings.svg
└── simpleui/
    ├── library.svg
    └── settings.svg
```

也支持包含完整 KOReader 相对路径的 ZIP：

```text
resources/icons/mdlight/*.svg
plugins/simpleui.koplugin/icons/*.svg
```

ZIP 内同样支持直接平铺 SVG。图标包可以只替换一部分图标，缺少的部分会自动沿用官方默认图标。

---

## 维护与更新

官方内置图标文件位于插件目录的 `official/` 下。如需同步更新上游官方图标，可在项目根目录下运行维护脚本：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\fetch_official_icons.ps1
```

该脚本会自动抓取最新版本的官方图标包并校验文件完整性。

---

## 许可证 / License

Copyright (C) 2026 THE-XSX

本项目采用 **GNU Affero 通用公共许可证第 3 版或任一更新版本**（`AGPL-3.0-or-later`）授权，完整条文见 [LICENSE](LICENSE)。

之所以选 AGPL 而非更宽松的许可证：KOReader 本体即以 AGPL-3.0 授权，本插件在同一进程内调用其 API，并与之组合后才能运行与分发。保持与上游一致可避免组合作品出现许可证冲突，也保留了将来向 KOReader 官方仓库提交合并的可能。

你可以自由使用、修改并再分发本插件。分发修改版时，需同样以 `AGPL-3.0-or-later` 开源、保留版权与许可声明，并标注改动之处。特别地，许可证第 13 条规定：若你经由网络将修改版提供给他人使用，必须向这些使用者提供对应版本的源码。

本项目按「原样」提供，不附带任何明示或默示的担保，包括但不限于对适销性与特定用途适用性的担保。

This program is free software: you can redistribute it and/or modify it under the terms of the **GNU Affero General Public License** as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. See [LICENSE](LICENSE) for the full text.

AGPL-3.0 was chosen to match KOReader itself, which is AGPL-3.0 licensed. This plugin calls KOReader's API in-process and only runs as part of that combined work, so matching the upstream license avoids a license conflict in the combination — and keeps the door open to upstreaming.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for more details.
