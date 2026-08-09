# rougelike_game

类吸血鬼幸存者（Vampire Survivors-like）肉鸽游戏，技术栈 **Godot 4**（GDScript），PC + Web 双端目标。

> 设计文档见同目录 [`GDD.md`](GDD.md)（v0.1 草案，含核心循环 / 武器 / 敌人 / 波次 / 元进度 / 技术架构）。

## 工程结构

```
rougelike_game/
├── project.godot            # Godot 4 工程配置（已注册 autoload 与主场景）
├── icon.svg
├── data/                   # 数据驱动 JSON（不硬编码数值）
│   ├── weapons.json        # 武器表（projectile / aura / orbit 三类）
│   ├── passives.json       # 被动道具表
│   ├── evolutions.json     # 进化配方表
│   ├── enemies.json        # 敌人表（小怪/快速/精英/Boss）
│   ├── waves.json          # 时间线事件（解锁/倍率/Boss/20 分钟）
│   └── characters.json     # 角色表（首发 1 + 待解锁 3）
├── autoload/               # 全局单例（GDD §11.1）
│   ├── data_tables.gd      # JSON 加载与查询
│   ├── game_manager.gd     # 局内状态机 / 经验 / 计时
│   ├── upgrade_pool.gd     # 三选一池管理
│   ├── spawn_manager.gd    # 波次生成调度
│   ├── save_manager.gd     # 金币元进度存档（user://）
│   └── audio_manager.gd    # 音效占位（待接入素材）
├── scripts/
│   ├── entities/           # 玩家 / 敌人 / 宝石 / 弹道 / 武器基类
│   └── ui.gd               # HUD / 升级弹窗 / 结算界面
└── scenes/
    ├── main.gd             # 世界编排与主循环（M1~M3）
    └── main.tscn           # 启动场景
```

## 如何运行

1. 安装 [Godot 4.3+](https://godotengine.org/)（标准版或 .NET 版均可）。
2. 用 Godot 打开 `rougelike_game/` 文件夹（识别 `project.godot`）。
3. 按 F5 直接运行 `main.tscn`，或编辑器内 ▶ 运行。
4. 操作：WASD / 方向键移动；武器自动攻击；升级时弹窗按 `1/2/3` 或点击选择；死亡/通关后结算，点「再来一局」重开。

> 本工程由 AI 在你选定 Godot 4 后 scaffold，当前实现了 **M1（移动+自动攻击+尸潮+死亡）→ M2（经验宝石+升级三选一+被动+金币）→ M3（时间曲线缩放+Boss+20 分钟倒计时+结算）** 的可玩闭环。进化系统、元进度商店、美术/音频为后续里程碑。

## 已实现要点

- 数据驱动：所有数值在 `data/*.json`，新增武器 = 加一行 JSON + 一个行为类型。
- 对象池：敌人 / 弹道 / 宝石复用，避免频繁 inst/free。
- 时间驱动尸潮：`waves.json` 控制解锁、生成速率倍率、Boss 时点、敌人血量/伤害缩放。
- 三选一升级：未持有新武器优先、已选升级加权、满级不入池；武器满级 + 指定被动满级触发进化。
- 暂停式升级弹窗 + HUD + 结算 + 金币存档。

## 已知简化（后续迭代）

- 敌人之间未做分离斥力（会堆叠），M1 阶段可接受，后续按 GDD §11.3 加 SpatialHash。
- 障碍物目前只挡玩家、不挡敌人（GDD §8.1）。
- 渲染未上 `MultiMeshInstance2D`（GDD §11.3 性能预算），当前用 `_draw` 圆形占位，敌人数较少时流畅；大规模尸潮需切换实例化渲染。
- 美术为程序化占位图形；音频为无操作占位，待接入免费素材库。
