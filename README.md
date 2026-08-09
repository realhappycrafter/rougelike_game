# rougelike_game

[![Godot CI](https://github.com/realhappycrafter/rougelike_game/actions/workflows/ci.yml/badge.svg)](https://github.com/realhappycrafter/rougelike_game/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

类吸血鬼幸存者（Vampire Survivors-like）的肉鸽（Roguelite）游戏，技术栈 **Godot 4**（GDScript），目标平台 **Web + Android**。

> 设计文档见同目录 [`GDD.md`](GDD.md)（v0.1 草案，含核心循环 / 武器 / 敌人 / 波次 / 元进度 / 技术架构）。

## ✨ 特性

- **20 分钟一局**：随时间缩放的尸潮、阶段解锁、Boss、倒计时结算。
- **数据驱动**：所有数值在 `data/*.json`，新增武器 = 加一行 JSON + 一个行为类型（projectile / aura / orbit）。
- **三选一升级**：未持有新武器优先、已选升级加权、满级不入池；武器满级 + 指定被动满级触发进化。
- **对象池**：敌人 / 弹道 / 宝石复用，避免频繁 inst/free。
- **Web / Android 双端**：Web 端用 `gl_compatibility` 渲染器，适配低功耗设备。
- **联机就绪**：内置 WebSocket 中继（`tools/relay/`），支持局域网与公网隧道联机。

## 🎮 操作

| 操作 | 按键 |
| --- | --- |
| 移动 | `WASD` / 方向键 |
| 攻击 | 自动攻击（无需操作） |
| 升级选择 | `1` / `2` / `3` 或鼠标点击 |
| 重开 | 结算界面点「再来一局」 |

触屏设备：左下方虚拟摇杆移动。

## 🛠 技术栈

- **引擎**：Godot 4.7.x（GDScript，无 C# 依赖）
- **渲染**：2D 俯视，`gl_compatibility` 兼容渲染器（Web/移动端）
- **数据**：JSON 表驱动（`autoload/data_tables.gd` 加载与查询）
- **联机**：Node.js WebSocket 中继（`tools/relay/server.js`）

## 📁 工程结构

```
rougelike_game/
├── project.godot            # Godot 4 工程配置
├── export_presets.cfg       # Web / Android 导出预设
├── data/                   # 数据驱动 JSON（不硬编码数值）
│   ├── weapons.json        # 武器表（projectile / aura / orbit 三类）
│   ├── passives.json       # 被动道具表
│   ├── evolutions.json     # 进化配方表
│   ├── enemies.json        # 敌人表（小怪 / 快速 / 精英 / Boss）
│   ├── waves.json          # 时间线事件（解锁 / 倍率 / Boss / 20 分钟）
│   └── characters.json     # 角色表
├── autoload/               # 全局单例（GameManager / UpgradePool / SaveManager ...）
├── scripts/                # 实体与系统逻辑（entities / systems）
├── scenes/                 # 主场景（main.tscn）与菜单
├── tools/relay/            # 联机 WebSocket 中继服务（Node.js）
└── web_build/              # Web 导出产物（git 忽略）
```

## 🚀 快速开始

### 前置要求

- [Godot 4.7.1+](https://godotengine.org/download)（标准版即可，无需 .NET 版）

### 在编辑器中运行

1. 用 Godot 打开 `rougelike_game/` 文件夹（识别 `project.godot`）。
2. 按 `F5` 运行 `main.tscn`，或点编辑器 ▶ 运行。

## 📦 导出（命令行）

仓库根目录在 `rougelike_game/`，使用 Godot 无头模式导出：

```bash
# Web（产物写入 build/web/）
godot --headless --path . --export-release "Web" build/web/index.html

# Android（产物写入 build_android/，该目录已被 .gitignore 忽略）
godot --headless --path . --export-release "Android" build_android/rougelike_debug.apk
```

> **Android 包名说明**：默认（非 gradle）导出会忽略 `package_name`，包名由显示名派生为
> `com.example.<小写显示名去空格>`。如需自定义反域名包名，需在 Godot 编辑器执行
> *Project → Install Android Build Template* 后走 gradle 构建。

## 🧩 开发约定

- **数据驱动优先**：加系统前先查 `data/*.json` 能否用数据表达；优先加数据而非加代码。
- **新增武器**：`data/weapons.json` 加一行 + 在对应 `WeaponBase` 行为类型里实现，不硬编码。
- **性能预算**：大规模尸潮走对象池 / SpatialHash；Web 端同屏实体数更紧，必要时切换 `MultiMeshInstance2D`。

## 🗺 路线图

- [ ] 进化系统（weapons × passives 组合进化）
- [ ] 元进度商店（金币解锁角色 / 起始武器）
- [ ] 美术 / 音频素材接入（当前为程序化占位）
- [ ] 多端联机对战 / 合作

## 🤝 贡献

欢迎提 Issue 与 PR：

- Bug 反馈 / 功能建议请使用仓库的 [Issue 模板](.github/ISSUE_TEMPLATE/)。
- 提交 PR 前请阅读 [PR 模板](.github/pull_request_template.md)，确保 CI（编辑器加载校验 + Web 导出）通过。

## 📄 许可证

[MIT](LICENSE) © 2026 realhappycrafter
