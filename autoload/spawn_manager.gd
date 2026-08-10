extends Node
## SpawnManager —— 时间驱动的波次生成调度（GDD §5.3）
## 以 run_time 为唯一变量：持续生成小怪 + 定时解锁/倍率/Boss 事件。

var unlocked = {}
var rate_mult = 1.0
var spawn_accum = 0.0

func reset() -> void:
	unlocked = {}
	rate_mult = 1.0
	spawn_accum = 0.0

func update(t: float, delta: float, world, spawner) -> void:
	# 普通怪持续生成（rate_mult 由 main 按阶段设置；难度系数来自 GameManager.diff）
	# 优先读当前地图的刷怪速率，回退到全局 waves 表（向后兼容）
	var m = GameManager.current_map
	var base = float(m.get("base_spawn_rate", DataTables.waves.get("base_spawn_rate", 2.0)))
	var growth = float(m.get("spawn_growth", DataTables.waves.get("spawn_growth", 0.5)))
	var rate = base * (1.0 + t / 60.0 * growth) * rate_mult * GameManager.diff.spawn
	spawn_accum += rate * delta
	while spawn_accum >= 1.0:
		spawn_accum -= 1.0
		spawner.spawn_random_enemy()
