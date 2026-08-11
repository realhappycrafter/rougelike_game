extends Node
## GameManager —— 局内状态机与核心数值（GDD §11.1）
## 仅作为数据与信号中枢；世界/实体的实际编排在 main.gd 中完成。

signal hud_changed()
signal level_up_requested(options: Array)
signal run_ended(stats: Dictionary)

var playing = false
var run_time = 0.0
var kills = 0
var gold = 0
var level = 1
var exp = 0
var exp_needed = 0
var enemy_scale = 1.0

# 难度系统（GDD §16#3 + 用户需求：不同难度影响怪物强度与奖励）
var difficulty_id = "normal"
var diff = { "enemy_hp": 1.0, "enemy_dmg": 1.0, "exp": 1.0, "coin": 1.0, "spawn": 1.0 }

# 地图系统（诸天万界，顺序解锁，难度逐级递增）
var map_id = "zombie"
var current_map: Dictionary = {}

# 局外强化乘数（由 meta_upgrades 的 gold_gain / exp_gain 推导）
var meta_gold_mult = 1.0
var meta_exp_mult = 1.0

# Boss 奖励：击杀 Boss 后必定给一个红色品质词条
var red_reward_queued = false

var player = null          # 玩家实体引用（由 main 注入）

# ---- 联机状态（零成本方案：WebSocket 中继 + host 权威）----
enum NetMode { SOLO, HOST, GUEST }
var net_mode: int = NetMode.SOLO
var my_pid: int = 0
var peers: Dictionary = {}          # pid -> {host:bool, name:String, color:Color}
# 参与战斗模拟的玩家节点列表（host 端 = 本人 + 各客机代理；客机端 = 空，模拟交给 host）
var combat_players: Array = []

func get_players_for_combat() -> Array:
	return combat_players

var world = null           # 世界节点引用（由 main 注入）

var pending_levels = 0
var level_up_open = false

func _ready() -> void:
	# Web 端没有系统字体回退：必须显式把中文字体主题挂到根视口，
	# 否则所有 Label/Button 会回退到 Godot 内置拉丁默认字体（中文显示为方块/乱码）。
	# 注：gui/theme/default_theme 工程设置不会自动挂载到场景根，故在此显式设置。
	get_tree().root.theme = preload("res://ui_theme.tres")

func set_difficulty(id: String) -> void:
	if not DataTables.difficulties.has(id):
		id = "normal"
	difficulty_id = id
	var d = DataTables.difficulties[id]
	diff = {
		"enemy_hp": float(d.enemy_hp),
		"enemy_dmg": float(d.enemy_dmg),
		"exp": float(d.exp),
		"coin": float(d.coin),
		"spawn": float(d.spawn)
	}

## 设置当前地图（由主菜单选择流程调用，菜单处已校验解锁状态）
func set_map(id: String) -> void:
	if not DataTables.maps.has(id):
		id = "zombie"
	map_id = id
	current_map = DataTables.maps[id]
	compute_meta_multipliers()

## 由 meta_upgrades 的 gold_gain / exp_gain 推导全局乘数
func compute_meta_multipliers() -> void:
	meta_gold_mult = 1.0
	meta_exp_mult = 1.0
	if DataTables.meta_upgrades.has("gold_gain"):
		var lvl = float(SaveManager.get_meta_level("gold_gain"))
		meta_gold_mult = 1.0 + float(DataTables.meta_upgrades["gold_gain"]["per_level"]) * lvl
	if DataTables.meta_upgrades.has("exp_gain"):
		var lvl = float(SaveManager.get_meta_level("exp_gain"))
		meta_exp_mult = 1.0 + float(DataTables.meta_upgrades["exp_gain"]["per_level"]) * lvl

func start_run(p_world, p_player) -> void:
	world = p_world
	player = p_player
	playing = true
	run_time = 0.0
	kills = 0
	gold = 0
	level = 1
	exp = 0
	enemy_scale = 1.0
	pending_levels = 0
	level_up_open = false
	red_reward_queued = false
	exp_needed = exp_need(1)
	emit_signal("hud_changed")

## 升级经验曲线（GDD §6.1）
func exp_need(lv: int) -> int:
	return 5 + floor((lv - 1) * 8 * (1 + (lv - 1) * 0.06))

func add_exp(amount: int) -> void:
	if not playing:
		return
	var gain = int(round(float(amount) * meta_exp_mult))
	exp += gain
	var leveled = false
	while exp >= exp_needed:
		exp -= exp_needed
		level += 1
		exp_needed = exp_need(level)
		pending_levels += 1
		leveled = true
	if leveled:
		_on_level_gained()
	if pending_levels > 0 and not level_up_open:
		open_next_level_up()
	emit_signal("hud_changed")

## 每次升级的额外奖励（用户需求：三选一之外，回满血 / 吸取全图经验 / +20 血量上限）
func _on_level_gained() -> void:
	if player == null:
		return
	# 1) 回满血
	player.hp = player.max_hp
	# 2) 提升 20 血量上限（满血后当前 hp 也同步包含新增上限）
	player.base_max_hp += 20.0
	player.max_hp += 20.0
	player.hp = player.max_hp
	# 3) 吸取全图经验：立即结算所有 exp 宝石
	var gems = get_tree().get_nodes_in_group("gems")
	var collected = 0
	for g in gems:
		if g.type == "exp" and g.alive:
			collected += g.value
			g.alive = false
			g.visible = false
			g.remove_from_group("gems")
			if g.main and g.main.has_method("return_gem"):
				g.main.return_gem(g)
	if collected > 0:
		# 可能再次升级（会再调用本函数），但宝石已清空，安全终止
		add_exp(collected)

func open_next_level_up() -> void:
	var options = UpgradePool.generate(player)
	if options.is_empty():
		# 安全兜底：理论上 generate 总会返回金币宝箱选项，这里仅防极端回归导致静默吞掉升级。
		# 直接清空排队升级并通知 HUD，避免无限递归或升级界面消失。
		pending_levels = 0
		level_up_open = false
		emit_signal("hud_changed")
		return
	level_up_open = true
	emit_signal("level_up_requested", options)

## 玩家选择完一项后由 main 调用，继续处理排队中的升级
func resolve_level_up() -> void:
	pending_levels -= 1
	level_up_open = false
	if pending_levels > 0:
		open_next_level_up()
	else:
		emit_signal("hud_changed")

## Boss 奖励机制：击杀 Boss 直接升一级，并必定掉落一个红色品质词条
func boss_reward() -> void:
	if not playing:
		return
	level += 1
	pending_levels += 1
	red_reward_queued = true
	exp = 0
	exp_needed = exp_need(level)
	# 先标记 UI 已占用，避免 _on_level_gained 内吸取经验触发 add_exp 时提前弹出升级界面
	level_up_open = true
	_on_level_gained()
	if not level_up_open:
		open_next_level_up()
	emit_signal("hud_changed")

func add_kill() -> void:
	kills += 1
	emit_signal("hud_changed")

func end_run(reason: String) -> void:
	if not playing:
		return
	playing = false
	var stats = {
		"time": run_time,
		"kills": kills,
		"gold": gold,
		"level": level,
		"reason": reason
	}
	# 通关（生存到 20 分钟并清完 Boss）则记录地图进度并解锁下一界
	if reason == "win" and map_id != "":
		SaveManager.mark_map_cleared(map_id)
	SaveManager.add_gold(gold)
	SaveManager.record_run(SaveManager.get_active_slot(), run_time, level)
	emit_signal("run_ended", stats)

## 最近敌人查询已迁移到 EnemyManager（数据驱动 + 空间哈希）。
## 保留此函数仅作兼容占位：返回 null（调用方应改用 EnemyManager.get_nearest）。
func get_nearest_enemy(_from: Vector2):
	return null
