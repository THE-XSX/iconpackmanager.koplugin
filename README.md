# 图标包管理器 (Icon Pack Manager)

适用于 KOReader 的图标包切换插件，支持管理以下图标目录：

- `resources/icons/mdlight`（KOReader 原版图标）
- `plugins/simpleui.koplugin/icons`（Simple UI 图标，**可选**，未安装时自动跳过）

---

## 特性

* **安全无损与原子切换**：首次使用需先执行“备份原版图标”，插件会在独立保护目录校验并持久化保存原版资源；每次切换时先用原版备份作为基底叠加新图标，切换异常自动秒级回滚。
* **双向兼容 Simple UI**：自动检测设备是否安装 Simple UI 插件。安装了则双目录协同管理，未安装则自动降级为仅管理 KOReader 原版图标。
* **智能格式识别**：支持多主题平铺文件夹、嵌套版本子文件夹，以及结构化 ZIP 压缩包。
* **完整性检测报告**：直观查看每个图标包的覆盖率、缺失的原版图标列表及未知 SVG。

---

## 安装与使用

1. 将 `iconpackmanager.koplugin` 文件夹整体放入 KOReader 的 `plugins/` 目录并重启 KOReader。
2. 打开“工具 -> 图标包管理器”，先执行“**备份原版图标**”。
3. 点击“**图标包文件夹**”选择保存主题文件夹或 ZIP 的目录（如 `/sdcard/icons` 或 `koreader/icons`）。
4. 可先打开“**图标完整性检测**”，查看每个主题的图标覆盖情况。
5. 打开“**扫描到的图标包**”，选择一个主题并确认“**一键更换**”。
6. 按提示重启 KOReader 即可生效。
7. 如需还原，随时点击“**恢复原版图标**”并重启。

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

* 平铺文件会按文件名与当前 KOReader（以及 Simple UI）图标匹配；同名图标在两个目标中都存在时会同时替换。
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

ZIP 内同样支持直接平铺 SVG。图标包可以只替换一部分图标，缺少的部分会自动沿用原版图标。

---

## 注意事项

1. **KOReader OTA 在线升级**：
   * KOReader 在线 OTA 升级时会重置 `resources/icons/mdlight`。
   * 升级 KOReader 版本后，建议先在插件中执行一次“恢复原版图标”或重新备份，然后再重新应用你喜爱的主题。
2. **备份与设置路径**：
   * 备份文件保存在 `settings/iconpackmanager/original/`。
   * 设置保存在 `settings/iconpackmanager.lua`。
   * 卸载插件前如需保留恢复原版的能力，请勿随意删除该备份目录。

---

## 开源许可证

本项目基于 [GPL-3.0](LICENSE) 许可证开源。
