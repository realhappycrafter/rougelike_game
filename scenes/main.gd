extends Node2D
## Main —— 世界编排与主循环（GDD §11 架构）
## M1 移动+攻击+尸潮+死亡；M2 经验/升级/被动/金币；M3 时间/Boss/20 分钟/结算。
## 敌人由 EnemyManager（数据驱动 + 空间哈希）统一管理，主场景只负责生成调度与掉落。
##
## 联机（零成本方案：WebSocket 中继 + host 权威）：
##   - 默认 SOLO，完全不影响单人玩法。开局弹出联机面板（按 N 开关）。
##   - HOST：继续本地完整模拟，为每位客机建代理玩家（net_controlled），~20Hz 广播世界快照。
##   - GUEST：关闭本地模拟，发送输入 + 用快照做客户端预测/插值渲染（远端世界由 RemoteWorld 画）。
##   - 共享 build：升级同时应用到本人与所有代理（host 权威）；经验/金币/等级全局共享。

const MAP_W = 3200.0
const MAP_H = 2400.0
const SPAWN_MIN = 700.0
const SPAWN_MAX = 1200.0

const PlayerScript     = preload("res://scripts/entities/player.gd")
const GemScript        = preload("res://scripts/entities/gem.gd")
const ProjectileScript = preload("res://scripts/entities/projectile.gd")
const ChestScript      = preload("res://scripts/entities/chest.gd")
const UIScript         = preload("res://scripts/ui.gd")
const BGFloorScript    = preload("res://scripts/systems/bg_floor.gd")
const RemoteWorldScript = preload("res://scripts/systems/remote_world.gd")
const NetSerializeScript = preload("res://scripts/systems/net_serialize.gd")

var world: Node2D
var camera: Camera2D
var ui: Control
var player

var ui_layer = null          # CanvasLayer（屏幕空间 HUD + 联机面板）
var net_panel = null         # 联机入口面板
var remote_players = {}      # pid -> 客机代理 player 节点（仅 host 端使用）
var remote_world = null      # 客机端远端渲染器（RemoteWorld）

var _host_snap_acc = 0.0     # host 广播节流累加
var _input_acc = 0.0         # 客机输入发送节流累加
var _predicted_pos = Vector2.ZERO  # 客机本端化身预测位置
var _net_over = false        # 联机对局是否已结束（host 广播 gameover 后置位）

var projectile_pool = []
var gem_pool = []
var chest_pool = []
const CHEST_MAX = 20       # 同屏宝箱存在上限（超出回收最旧）
var active_chests = []     # 当前活动宝箱实例（用于上限封顶与清理）

# 普通怪（非精英、非 Boss）按难度的「总」数量上限（自己定的不卡档位）
var normal_cap = { "simple": 120, "normal": 200, "hard": 280, "purgatory": 360, "extreme": 400 }
# 精英怪：数量不限总数，但「每种」最多这么多（避免单一精英刷爆屏）
const ELITE_PER_TYPE: int = 5
# 宝箱品质权重分布（白/绿/蓝/紫/金/红，对应 11:9:7:5:3:1）。
# 除 Boss 箱（强制红箱）外，所有宝箱（阶段开局 / 定时 / 小怪1% / 精英）统一使用此分布。
const CHEST_Q_DIST = [11.0, 9.0, 7.0, 5.0, 3.0, 1.0]

# ---- 阶段 / 解锁状态 ----
var phases = []
var phase_idx = 0
var phase_state = "survival"   # "survival"（存活） | "boss"（Boss 战）
var phase_t = 0.0
var boss_uids = []
var boss_defeated = false
var last_level = 0
var _unlock_announced = {}
var chest_timer = 0.0

var current_options = []

## 解析命令行 `-- --map=<id>`，用于无头验证指定地图；未指定返回空串
func _cli_map() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--map="):
			var id = a.substr(6)
			if DataTables.maps.has(id):
				return id
			push_warning("[main] 命令行地图 id 不存在：" + id)
	return ""

## 无头长时程测试钩子：命令行 `--god` 时返回 true，使玩家免伤（正常游玩不传此参数）
func _cli_god() -> bool:
	for a in OS.get_cmdline_user_args():
		if a == "--god":
			return true
	return false

func _ready():
	# 选图优先级：命令行 `-- --map=<id>`（调试/无头验证） > 菜单已选 > 默认地图
	var forced_map = _cli_map()
	if forced_map != "":
		GameManager.set_map(forced_map)
	elif GameManager.current_map.is_empty():
		GameManager.set_map(GameManager.map_id)

	world = Node2D.new()
	add_child(world)

	# 背景：暗黑地牢地面（程序化绘制，见 bg_floor.gd）
	var bg = BGFloorScript.new()
	bg.name = "Floor"
	bg.map_w = MAP_W
	bg.map_h = MAP_H
	bg.z_index = -10
	# 按当前地图配色（floor 字段含 base/grid/border 三色）
	if GameManager.current_map.has("floor"):
		var fl = GameManager.current_map["floor"]
		if fl.has("base"):   bg.floor_base = Color(fl.base[0], fl.base[1], fl.base[2])
		if fl.has("grid"):   bg.floor_grid = Color(fl.grid[0], fl.grid[1], fl.grid[2])
		if fl.has("border"): bg.floor_border = Color(fl.border[0], fl.border[1], fl.border[2])
	world.add_child(bg)

	_build_walls()

	# 相机
	camera = Camera2D.new()
	world.add_child(camera)

	# UI（屏幕空间，常驻处理）—— 用 CanvasLayer 隔离相机，保证 HUD 不随世界滚动
	ui_layer = CanvasLayer.new()
	add_child(ui_layer)
	ui = Control.new()
	ui.set_script(UIScript)
	ui_layer.add_child(ui)

	# 玩家
	player = CharacterBody2D.new()
	player.set_script(PlayerScript)
	world.add_child(player)
	player.global_position = Vector2.ZERO
	player.main = self

	# 敌人系统：重置并挂载渲染表面到 world，连接死亡信号（去重，避免重开叠加）
	EnemyManager.reset()
	EnemyManager.attach_to_world(world)
	# 敌人地图边界（与玩家物理墙对齐） + 内部障碍（柱子：挡玩家也挡敌人）
	EnemyManager.set_bounds(Vector2(-MAP_W / 2, -MAP_H / 2), Vector2(MAP_W / 2, MAP_H / 2))
	_build_obstacles()
	if not EnemyManager.is_connected("enemy_died", on_enemy_died):
		EnemyManager.connect("enemy_died", on_enemy_died)

	# 信号连接
	GameManager.connect("level_up_requested", _on_level_up_requested)
	GameManager.connect("run_ended", _on_run_ended)
	GameManager.connect("hud_changed", _on_hud_changed)
	ui.connect("option_selected", _on_option_chosen)
	ui.connect("restart_requested", _on_restart)

	SpawnManager.reset()
	ui.init_hud()
	init_run_phases()
	GameManager.start_run(world, player)
	if GameManager.difficulty_id == "extreme":
		ui.show_perf_warning("⚠ 极端模式：敌人数量极多，低端设备可能出现卡顿")
	player.setup_character(DataTables.characters["default"])
	# 局外强化（meta_upgrades）叠加到基础属性
	player.apply_meta_upgrades(SaveManager.get_meta_upgrades())
	# 无头长时程测试：--god 免伤，覆盖 Boss/通关分支
	if _cli_god():
		player.god_mode = true
		push_warning("[main] 无头测试免伤模式已启用（--god）")
	# 开场旁白（诸天万界世界观）
	var m = GameManager.current_map
	if m.has("story_intro") and ui != null:
		ui.show_story(m.get("world", ""), m.get("name", "未知界域"), m.get("story_intro", ""))

	# ---- 联机接入层（默认 SOLO，开局可选主机/客机/单人）----
	GameManager.combat_players = [player]
	remote_players = {}
	NetManager.connect("connected_changed", _on_net_connected_changed)
	NetManager.connect("message_received", _on_net_message)
	_build_net_panel()
	net_panel.visible = true   # 开局即弹出，玩家可选模式

	_on_hud_changed()

func _build_walls():
	# 地图中心在原点，边界 x∈[-1600,1600] y∈[-1200,1200]
	var walls = [
		{ "pos": Vector2(0, -MAP_H / 2 - 20), "size": Vector2(MAP_W + 80, 40) },
		{ "pos": Vector2(0,  MAP_H / 2 + 20), "size": Vector2(MAP_W + 80, 40) },
		{ "pos": Vector2(-MAP_W / 2 - 20, 0), "size": Vector2(40, MAP_H + 80) },
		{ "pos": Vector2( MAP_W / 2 + 20, 0), "size": Vector2(40, MAP_H + 80) }
	]
	for w in walls:
		var sb = StaticBody2D.new()
		sb.position = w.pos
		var col = CollisionShape2D.new()
		var shape = RectangleShape2D.new()
		shape.size = w.size
		col.shape = shape
		sb.add_child(col)
		world.add_child(sb)

## 内部障碍（柱子）：既是物理 StaticBody2D（挡玩家），也注册为数据障碍（挡敌人）。
## 远离出生点（原点），避免玩家一出生被卡。位置/尺寸即改即生效。
func _build_obstacles():
	var interior = [
		{ "pos": Vector2(450, 320),  "half": Vector2(70, 70) },
		{ "pos": Vector2(-520, -260), "half": Vector2(90, 45) },
		{ "pos": Vector2(260, -520),  "half": Vector2(55, 55) },
		{ "pos": Vector2(-340, 460),  "half": Vector2(45, 90) }
	]
	for ob in interior:
		var sb = StaticBody2D.new()
		sb.position = ob.pos
		var col = CollisionShape2D.new()
		var shape = RectangleShape2D.new()
		shape.size = ob.half * 2.0
		col.shape = shape
		sb.add_child(col)
		world.add_child(sb)
	# 敌人侧：整组替换数据障碍（autoload 持久化，重开场景不会累积重复）
	EnemyManager.set_obstacles(interior)

func _process(delta: float) -> void:
	if not GameManager.playing:
		return
	# 客机端：关闭本地模拟，仅做客户端预测/插值 + 发输入 + 远端渲染
	if GameManager.net_mode == GameManager.NetMode.GUEST:
		_client_tick(delta)
		return
	GameManager.run_time += delta
	GameManager.enemy_scale = _waves_scale(GameManager.run_time)
	_update_level_unlocks()
	_update_phases(delta)
	SpawnManager.update(GameManager.run_time, delta, world, self)
	_update_chests(delta)
	camera.global_position = camera.global_position.lerp(player.global_position, min(1.0, delta * 8.0))
	# 主机端：向客机广播世界快照（节流 ~20Hz）
	if GameManager.net_mode == GameManager.NetMode.HOST:
		_host_broadcast(delta)

func _waves_scale(t: float) -> float:
	# 优先读当前地图的强度曲线，回退到全局 waves 表
	var m = GameManager.current_map
	var b = float(m.get("enemy_scale_base", DataTables.waves.get("enemy_scale_base", 1.0)))
	var pm = float(m.get("enemy_scale_per_min", DataTables.waves.get("enemy_scale_per_min", 0.35)))
	return b + t / 60.0 * pm

## ---- 阶段机 / 等级解锁 ----
func init_run_phases() -> void:
	# 优先读当前地图的阶段配置，回退到全局 waves 表
	phases = GameManager.current_map.get("phases", DataTables.waves.get("phases", []))
	phase_idx = 0
	phase_state = "survival"
	phase_t = 0.0
	boss_uids.clear()
	boss_defeated = false
	last_level = 0
	_unlock_announced.clear()
	SpawnManager.unlocked.clear()
	chest_timer = 0.0
	if not phases.is_empty() and ui != null:
		ui.set_stage(0, "survival")
		ui.info("第 1 阶段开始！", Color(0.5, 0.9, 1.0))
	# 阶段开局：随机位置自然生成 15 个宝箱
	spawn_phase_chests(15)

## 按玩家等级解锁新的精英/普通怪（unlock_schedule），并广播「加入战场」
func _update_level_unlocks() -> void:
	var lv = GameManager.level
	if lv == last_level:
		return
	last_level = lv
	# 优先读当前地图的解锁表，回退到全局 waves 表
	var schedule = GameManager.current_map.get("unlock_schedule", DataTables.waves.get("unlock_schedule", []))
	for u in schedule:
		if int(u.level) <= lv and not _unlock_announced.has(u.enemy):
			_unlock_announced[u.enemy] = true
			SpawnManager.unlocked[u.enemy] = true
			if u.get("silent", false):
				continue
			var kind = u.get("kind", "normal")
			var prefix = "普通怪 " if kind == "normal" else "精英怪 "
			if ui != null:
				ui.info(prefix + u.name + " 加入战场！", Color(0.9, 0.8, 0.4))

## 阶段推进：存活阶段到点刷 Boss；Boss 阶段到点（无论是否被击杀）撤离
func _update_phases(delta: float) -> void:
	if phases.is_empty():
		return
	phase_t += delta
	var ph = phases[phase_idx]
	if phase_state == "survival":
		SpawnManager.rate_mult = 1.0
		if phase_t >= float(ph.survival):
			_start_boss_phase(ph)
	else:  # boss
		SpawnManager.rate_mult = 0.45   # Boss 战期间降低普通怪密度，突出 Boss
		if phase_t >= float(ph.boss):
			_end_boss_phase(ph)

func _start_boss_phase(ph: Dictionary) -> void:
	phase_state = "boss"
	phase_t = 0.0
	boss_defeated = false
	var bid = ph.boss_enemy
	if DataTables.enemies.has(bid):
		var uid = EnemyManager.spawn(bid, rand_spawn_pos(), GameManager.enemy_scale)
		if uid >= 0:
			boss_uids.append(uid)
		var bn = DataTables.enemies[bid].name
		if ui != null:
			ui.info("BOSS战开启！！ " + bn + " 将追杀你！", Color(1.0, 0.3, 0.3), true)
		if ui != null:
			ui.set_stage(phase_idx, "boss")

func _end_boss_phase(ph: Dictionary) -> void:
	for uid in boss_uids:
		EnemyManager.despawn_uid(uid)
	boss_uids.clear()
	if not boss_defeated:
		if ui != null:
			ui.info("Boss 离开了战场……", Color(0.8, 0.8, 0.9))
		# Boss 必定掉落红色宝箱（即使未被击杀也保底一只红箱 + 必出红奖）
		spawn_chest_at(player.global_position + Vector2(randf() * 200.0 - 100.0, randf() * 200.0 - 100.0), 5)
	phase_idx += 1
	if phase_idx >= phases.size():
		GameManager.end_run("win")
	else:
		phase_state = "survival"
		phase_t = 0.0
		if ui != null:
			ui.set_stage(phase_idx, "survival")
			ui.info("第 " + str(phase_idx + 1) + " 阶段开始！", Color(0.5, 0.9, 1.0))
		# 新阶段开局：随机位置自然生成 15 个宝箱
		spawn_phase_chests(15)

## ---- 生成 ----
func unlocked_non_boss() -> Array:
	var out = []
	for eid in SpawnManager.unlocked.keys():
		if SpawnManager.unlocked[eid] and DataTables.enemies.has(eid):
			if not DataTables.enemies[eid].get("boss", false):
				out.append(eid)
	return out

func count_enemy_type(eid: String) -> int:
	return EnemyManager.count_type(eid)

func rand_spawn_pos() -> Vector2:
	var ang = randf() * TAU
	var r = SPAWN_MIN + randf() * (SPAWN_MAX - SPAWN_MIN)
	return player.global_position + Vector2(cos(ang), sin(ang)) * r

func spawn_enemy(eid: String) -> void:
	if not DataTables.enemies.has(eid):
		return
	var d = DataTables.enemies[eid]
	if d.get("boss", false):
		EnemyManager.spawn(eid, rand_spawn_pos(), GameManager.enemy_scale)
		return
	# 精英：每种上限（总数不限）
	if d.get("elite", false):
		if EnemyManager.count_type(eid) >= ELITE_PER_TYPE:
			return
		EnemyManager.spawn(eid, rand_spawn_pos(), GameManager.enemy_scale)
		return
	# 普通怪：按难度的总上限
	if EnemyManager.count_normal() >= normal_cap.get(GameManager.difficulty_id, 200):
		return
	EnemyManager.spawn(eid, rand_spawn_pos(), GameManager.enemy_scale)

## 加权随机刷怪：按 enemies.weight 抽取。已超上限的类型被跳过——
## 普通怪总上限满时只剩精英可刷（精英每种≤5，总数不限），互不挤占。
func spawn_random_enemy() -> void:
	var choices = unlocked_non_boss()
	if choices.is_empty():
		return
	var cap = normal_cap.get(GameManager.difficulty_id, 200)
	var normal_full = EnemyManager.count_normal() >= cap
	var avail: Array = []
	var total = 0.0
	for eid in choices:
		var d = DataTables.enemies[eid]
		if d.get("elite", false):
			if EnemyManager.count_type(eid) >= ELITE_PER_TYPE:
				continue
		else:
			if normal_full:
				continue
		avail.append(eid)
		total += float(d.get("weight", 10))
	if avail.is_empty():
		return
	var r = randf() * total
	for eid in avail:
		r -= float(DataTables.enemies[eid].get("weight", 10))
		if r <= 0.0:
			spawn_enemy(eid)
			return
	spawn_enemy(avail[avail.size() - 1])

## 按权重分布 roll 一个宝箱品质等级（0=白 … 5=红）。weights 长度须为 6。
func roll_chest_quality(weights: Array = CHEST_Q_DIST) -> int:
	var total = 0.0
	for w in weights:
		total += float(w)
	var r = randf() * total
	for i in range(weights.size()):
		r -= float(weights[i])
		if r <= 0.0:
			return i
	return 0

func on_enemy_died(snap: Dictionary) -> void:
	GameManager.add_kill()
	var is_boss = snap.get("boss", false)
	var is_elite = snap.get("elite", false)
	if is_boss:
		GameManager.boss_reward()
		boss_defeated = true
		var bn = DataTables.enemies.get(snap.eid, {}).get("name", "Boss")
		if ui != null:
			ui.info("你击败了 " + bn + "！", Color(0.6, 1.0, 0.6))
	spawn_gem(snap.pos, "exp", snap.exp_value)
	if randf() < 0.30:
		spawn_gem(snap.pos, "coin", snap.coin_value)
	# 普通怪：1% 概率掉落宝箱（按 11:9:7:5:3:1 分布）
	if not is_elite and not is_boss and randf() < 0.01:
		spawn_chest_at(snap.pos)
	# 精英：30% 概率掉落宝箱（品质按 11:9:7:5:3:1 分布）
	if is_elite:
		spawn_gem(snap.pos, "magnet", 0)
		if randf() < 0.30:
			spawn_chest_at(snap.pos)
	# Boss：必掉红箱，且 chest.gd 中红箱 100% 红奖（必出红色词条）
	if is_boss:
		spawn_gem(snap.pos, "magnet", 0)
		spawn_chest_at(snap.pos, 5)
	if player.hp < player.max_hp * 0.6 and randf() < 0.05:
		spawn_gem(snap.pos, "heal", 0)

func clear_enemies() -> void:
	EnemyManager.clear()

## ---- 地图奖励点（宝箱）----
## 在地图随机位置刷一个宝箱（品质按 11:9:7:5:3:1 分布）
func spawn_random_map_chest() -> void:
	var mx = MAP_W / 2.0 - 80.0
	var my = MAP_H / 2.0 - 80.0
	var p = Vector2((randf() * 2.0 - 1.0) * mx, (randf() * 2.0 - 1.0) * my)
	spawn_chest_at(p)

## 每个阶段开局在随机位置生成 n 个宝箱（需求：每阶段开局自然生成 15 个）
func spawn_phase_chests(n: int) -> void:
	for i in range(n):
		spawn_random_map_chest()

## 在指定位置刷一个宝箱（复用池）。quality<0 时按基础分布随机（开局/定时用）
func spawn_chest_at(pos: Vector2, quality: int = -1) -> void:
	# 同屏宝箱上限封顶：超过 CHEST_MAX 个时先回收最旧的
	if active_chests.size() >= CHEST_MAX:
		var old = active_chests.pop_front()
		if is_instance_valid(old):
			old.queue_free()
	var keys = DataTables.chests.keys()
	if keys.is_empty():
		return
	var rid = keys[randi() % keys.size()]
	var c
	if chest_pool.is_empty():
		c = Node2D.new()
		c.set_script(ChestScript)
		world.add_child(c)
	else:
		c = chest_pool.pop_back()
		if c.get_parent() == null:
			world.add_child(c)
		c.visible = true
	var q = quality if quality >= 0 else roll_chest_quality()
	c.spawn(pos, rid, self, q)
	active_chests.append(c)

## 每 15 秒在地图随机位置生成 1 个宝箱（用户需求：15 秒 1 个）
func _update_chests(delta: float) -> void:
	chest_timer += delta
	if chest_timer >= 15.0:
		chest_timer = 0.0
		spawn_random_map_chest()
	# 清理已过期 / 被回收的空引用（chest 自行 queue_free 后需移除）
	active_chests = active_chests.filter(func(c): return is_instance_valid(c))

## 宝箱开启回调：弹信息框
func on_chest_opened(desc: String) -> void:
	if ui != null:
		ui.info("宝箱开启获得了 " + desc, Color(1.0, 0.85, 0.4))

## ---- 掉落物 / 弹道 池 ----
func spawn_gem(pos, type, value):
	var g
	if gem_pool.is_empty():
		g = Node2D.new()
		g.set_script(GemScript)
		world.add_child(g)
	else:
		g = gem_pool.pop_back()
		if g.get_parent() == null:
			world.add_child(g)
		g.visible = true
	g.spawn(pos, type, value, self)

func return_gem(g) -> void:
	gem_pool.append(g)

func get_projectile():
	var p
	if projectile_pool.is_empty():
		p = Area2D.new()
		p.set_script(ProjectileScript)
		world.add_child(p)
	else:
		p = projectile_pool.pop_back()
		if p.get_parent() == null:
			world.add_child(p)
		p.visible = true
	return p

func return_projectile(p) -> void:
	projectile_pool.append(p)

## ---- 升级三选一（共享 build：host 权威，应用到本人与所有代理）----
func _on_level_up_requested(options: Array) -> void:
	current_options = options
	get_tree().paused = true
	ui.show_level_up(options)

func _on_option_chosen(index: int) -> void:
	if index >= 0 and index < current_options.size():
		_apply_shared_upgrade(current_options[index])
		_check_evolutions()
	ui.hide_level_up()
	get_tree().paused = false
	GameManager.resolve_level_up()

## 共享升级：同时应用到本人与所有客机代理（host 端 combat_players 已含代理）
func _apply_shared_upgrade(opt: Dictionary) -> void:
	for p in GameManager.combat_players:
		if is_instance_valid(p):
			p.apply_upgrade(opt)

func _check_evolutions() -> void:
	for p in GameManager.combat_players:
		if not is_instance_valid(p):
			continue
		for ev_id in DataTables.evolutions.keys():
			var ev = DataTables.evolutions[ev_id]
			if not p.weapons.has(ev.weapon):
				continue
			if p.weapons[ev.weapon].node.evolved:
				continue
			if p.weapons[ev.weapon].level < DataTables.weapons[ev.weapon].max_level:
				continue
			if not p.passives.has(ev.passive):
				continue
			if p.passives[ev.passive].level < DataTables.passives[ev.passive].max_level:
				continue
			p.weapons[ev.weapon].node.evolve()

## ---- 结算 / 重开 ----
func on_player_death() -> void:
	GameManager.end_run("dead")

## 客机代理在 host 端倒地：立即在主机附近复活（MVP，不影响整局）
func on_remote_death(rp) -> void:
	rp.downed = true
	rp.hp = rp.max_hp
	rp.global_position = player.global_position + Vector2(randf() * 160.0 - 80.0, randf() * 160.0 - 80.0)
	rp.downed = false

func _on_run_ended(stats: Dictionary) -> void:
	# 主机结束对局时，通知所有客机（客机无本地模拟，靠此收尾）
	if GameManager.net_mode == GameManager.NetMode.HOST:
		NetManager._send({"t": "gameover", "stats": stats})
	# 通关（win）：先放章节尾声旁白，再弹出结算面板
	if stats.get("reason", "") == "win" and GameManager.current_map.has("story_outro") and ui != null:
		var m = GameManager.current_map
		ui.show_story(m.get("world", ""), m.get("name", "未知界域") + " · 通关", m.get("story_outro", ""))
	ui.show_results(stats)

func _on_hud_changed() -> void:
	ui.update_hud()

func _on_restart() -> void:
	get_tree().paused = false
	get_tree().reload_current_scene()

# ==========================================================================
# 联机接入层（零成本：WebSocket 中继 + host 权威）
# ==========================================================================

## 构建联机入口面板（代码创建，无需改 .tscn）
func _build_net_panel() -> void:
	net_panel = Control.new()
	net_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	net_panel.mouse_filter = Control.MOUSE_FILTER_STOP

	# 半透明背景
	var bg = ColorRect.new()
	bg.color = Color(0.05, 0.05, 0.09, 0.92)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	net_panel.add_child(bg)

	var vbox = VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	vbox.custom_minimum_size = Vector2(380, 340)
	net_panel.add_child(vbox)

	var title = Label.new()
	title.text = "联机模式（零成本 WebSocket 中继）"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 20)
	vbox.add_child(title)

	var hint = Label.new()
	hint.text = "第一个进房者为主机（权威），其余为客机。\n按 N 可随时开关此面板。"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(hint)

	var room_le = LineEdit.new()
	room_le.placeholder_text = "房间名（如 room1）"
	room_le.text = "room1"
	vbox.add_child(room_le)

	var url_le = LineEdit.new()
	url_le.placeholder_text = "中继地址 ws://host:port"
	url_le.text = _default_relay_url()
	vbox.add_child(url_le)

	var b_host = Button.new(); b_host.text = "创建房间（主机 / 权威）"; vbox.add_child(b_host)
	var b_guest = Button.new(); b_guest.text = "加入房间（客机）"; vbox.add_child(b_guest)
	var b_solo = Button.new(); b_solo.text = "单人游戏（跳过）"; vbox.add_child(b_solo)

	var status = Label.new(); status.name = "Status"
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(status)

	b_host.connect("pressed", func(): _connect_as(true, room_le.text, url_le.text))
	b_guest.connect("pressed", func(): _connect_as(false, room_le.text, url_le.text))
	b_solo.connect("pressed", func(): _close_net_panel())

	net_panel.visible = false
	ui_layer.add_child(net_panel)

func _default_relay_url() -> String:
	# 中继服务器同时托管网页与 WebSocket（tools/relay/server.js），二者必定同源。
	# 因此 Web 端直接由当前页面地址推导中继地址：
	#   http://192.168.0.107:8080/  -> ws://192.168.0.107:8080   （局域网）
	#   https://xxx.trycloudflare.com/ -> wss://xxx.trycloudflare.com （公网隧道）
	# 若写死 localhost，别的机器打开页面会连到它自己，联机必然失败。
	if OS.has_feature("web"):
		var host = JavaScriptBridge.eval("window.location.host", true)
		var proto = JavaScriptBridge.eval("window.location.protocol", true)
		if typeof(host) == TYPE_STRING and str(host) != "":
			var scheme = "wss://" if str(proto) == "https:" else "ws://"
			return scheme + str(host)
	# 桌面/无头运行：默认连本机中继
	return "ws://localhost:8080"

func _set_status(s: String) -> void:
	if net_panel == null:
		return
	var st = net_panel.find_child("Status", true, false)
	if st != null:
		st.text = s

func _connect_as(is_host: bool, room: String, url: String) -> void:
	GameManager.net_mode = GameManager.NetMode.HOST if is_host else GameManager.NetMode.GUEST
	NetManager.connect_relay(url, room, is_host)
	_set_status("正在连接 %s 房间「%s」…" % [url, room])

func _close_net_panel() -> void:
	if net_panel != null:
		net_panel.visible = false

func _on_net_connected_changed(ok: bool) -> void:
	if ok:
		_set_status("已连接（pid=%d，模式=%s）" % [NetManager.my_pid, "主机" if GameManager.net_mode == GameManager.NetMode.HOST else "客机"])
		net_panel.visible = false
		if GameManager.net_mode == GameManager.NetMode.GUEST:
			_enter_guest_mode()
		else:
			_enter_host_mode()
	else:
		_set_status("连接已断开")
		GameManager.net_mode = GameManager.NetMode.SOLO

func _on_net_message(msg: Dictionary) -> void:
	var t = msg.get("t", "")
	if t == "join":
		var pid = int(msg.get("pid", -1))
		if pid < 0 or pid == GameManager.my_pid:
			return
		# 仅主机需要为客机建代理玩家（net_controlled，由客机输入驱动）。
		# 客机端不建代理节点——它通过快照在 RemoteWorld 中渲染所有其他玩家（含主机），
		# 若也建代理会导致主机被重复渲染成一个无人驱动的静止化身。
		if GameManager.net_mode != GameManager.NetMode.HOST:
			return
		if not remote_players.has(pid):
			_spawn_remote_player(pid)
	elif t == "peer_leave":
		var pid = int(msg.get("pid", -1))
		if remote_players.has(pid):
			var rp = remote_players[pid]
			if is_instance_valid(rp):
				rp.queue_free()
			remote_players.erase(pid)
			_rebuild_combat_players()
	elif t == "input":
		var pid = int(msg.get("pid", -1))
		if remote_players.has(pid):
			remote_players[pid].set_net_intent(Vector2(float(msg.mx), float(msg.my)), Vector2(float(msg.ax), float(msg.ay)))
	elif t == "gameover":
		_net_over = true
		ui.show_results(msg.get("stats", {}))

## 主机进入：以自身为权威继续模拟，等待客机加入
func _enter_host_mode() -> void:
	GameManager.my_pid = NetManager.my_pid if NetManager.my_pid >= 0 else 0
	player.pid = GameManager.my_pid
	player.net_color = _pid_color(GameManager.my_pid)
	player.net_controlled = false
	player.is_remote_render = false
	remote_players = {}
	GameManager.combat_players = [player]
	_host_snap_acc = 0.0

## 客机进入：关闭本地模拟，改用快照渲染 + 客户端预测
func _enter_guest_mode() -> void:
	GameManager.my_pid = NetManager.my_pid
	GameManager.combat_players = []   # 客机不跑本地战斗模拟
	player.is_remote_render = true    # 本端化身位置由快照预测/插值驱动
	player.net_controlled = false
	player.pid = GameManager.my_pid
	player.net_color = _pid_color(GameManager.my_pid)
	_predicted_pos = player.global_position
	if remote_world == null:
		remote_world = Node2D.new()
		remote_world.set_script(RemoteWorldScript)
		remote_world.self_pid = GameManager.my_pid
		remote_world.z_index = 1
		world.add_child(remote_world)

## 主机：为加入的客机建一个代理玩家（由客机输入驱动），并镜像当前共享 build
func _spawn_remote_player(pid: int) -> void:
	var rp = CharacterBody2D.new()
	rp.set_script(PlayerScript)
	rp.main = self
	rp.global_position = player.global_position + Vector2(randf() * 200.0 - 100.0, randf() * 200.0 - 100.0)
	rp.setup_character(DataTables.characters["default"])
	rp.net_controlled = true
	rp.pid = pid
	rp.net_color = _pid_color(pid)
	world.add_child(rp)
	remote_players[pid] = rp
	# 镜像主机当前共享 build（武器 + 等级）到新代理，保证一致
	for wid in player.weapons.keys():
		if not rp.weapons.has(wid):
			rp._equip_weapon(wid, player.weapons[wid].level)
		else:
			rp.weapons[wid].level = player.weapons[wid].level
			rp.weapons[wid].node.on_level_up(player.weapons[wid].level)
	_rebuild_combat_players()

func _rebuild_combat_players() -> void:
	var arr = [player]
	for pid in remote_players.keys():
		arr.append(remote_players[pid])
	GameManager.combat_players = arr

## 主机：~20Hz 广播世界快照（玩家 + 敌人紧凑数组 + 共享进度 + 掉落物）
func _host_broadcast(delta: float) -> void:
	_host_snap_acc += delta
	if _host_snap_acc < 0.05:
		return
	_host_snap_acc = 0.0
	NetManager.send_state(_build_snapshot())

## 构造主机权威世界快照（仅收集实时数据，序列化交给 NetSerialize 纯函数，便于单测）。
## 新增：全局共享进度（金币/等级/经验/升级所需）与掉落物（宝石/宝箱）数组，
## 客机端据此镜像共享进度并在 RemoteWorld 中渲染掉落。
func _build_snapshot() -> Dictionary:
	var player_entries = []
	for p in GameManager.combat_players:
		if is_instance_valid(p):
			player_entries.append(NetSerializeScript.serialize_player(p))
	var gem_entries = []
	for g in get_tree().get_nodes_in_group("gems"):
		if is_instance_valid(g) and g.alive:
			gem_entries.append(NetSerializeScript.serialize_gem(g))
	var chest_entries = []
	for c in active_chests:
		if is_instance_valid(c) and not c.taken:
			chest_entries.append(NetSerializeScript.serialize_chest(c))
	return NetSerializeScript.build_snapshot(
		player_entries,
		EnemyManager.serialize_compact(),
		gem_entries,
		chest_entries,
		GameManager.run_time,
		GameManager.kills,
		GameManager.gold,
		GameManager.level,
		GameManager.exp,
		GameManager.exp_needed
	)

## 客机：每帧——读输入→发输入→应用快照（远端渲染 + 本端预测/插值）
func _client_tick(delta: float) -> void:
	if _net_over:
		return
	if not NetManager.is_connected:
		return
	# 1) 读取本地输入
	var mv = Vector2.ZERO
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):    mv.y -= 1
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):  mv.y += 1
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):  mv.x -= 1
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT): mv.x += 1
	if TouchInput.active:
		mv += TouchInput.get_move_vector()
	if mv.length() > 1.0:
		mv = mv.normalized()
	if mv.length() > 0.0:
		mv = mv.normalized()
	var aim = mv
	# 2) 限频发送输入（~30Hz）
	_input_acc += delta
	if _input_acc >= 0.033:
		_input_acc = 0.0
		NetManager.send_input(mv, aim)
	# 3) 应用快照（远端渲染 + 本端预测/插值）
	var st = NetManager.last_state
	if st.is_empty() or not st.has("players"):
		return
	# 3a) 应用 host 广播的共享进度（等级/金币/经验/升级所需/击杀，全局一致）
	var shared_changed = false
	if st.has("g") and GameManager.gold != int(st.g):
		GameManager.gold = int(st.g); shared_changed = true
	if st.has("lv") and GameManager.level != int(st.lv):
		GameManager.level = int(st.lv); shared_changed = true
	if st.has("exp") and GameManager.exp != int(st.exp):
		GameManager.exp = int(st.exp); shared_changed = true
	if st.has("enn") and GameManager.exp_needed != int(st.enn):
		GameManager.exp_needed = int(st.enn); shared_changed = true
	if st.has("kills") and GameManager.kills != int(st.kills):
		GameManager.kills = int(st.kills); shared_changed = true
	if shared_changed:
		GameManager.hud_changed.emit()
	# 3b) 远端世界：敌人 + 其他玩家 + 掉落物（宝石/宝箱）
	remote_world.player_list = []
	remote_world.enemy_list = []
	remote_world.gem_list = []
	remote_world.chest_list = []
	var self_entry = null
	for p in st["players"]:
		if int(p.get("pid", -1)) == GameManager.my_pid:
			self_entry = p
		else:
			remote_world.player_list.append(p)
	if st.has("enemies"):
		remote_world.enemy_list = st["enemies"]
	if st.has("gems"):
		remote_world.gem_list = st["gems"]
	if st.has("chests"):
		remote_world.chest_list = st["chests"]
	if self_entry != null:
		var target = Vector2(float(self_entry.x), float(self_entry.y))
		# 本地预测 + 向权威位置插值（简化和解，减少延迟感）
		_predicted_pos += mv * player.speed * delta
		_predicted_pos.x = clamp(_predicted_pos.x, -MAP_W / 2.0, MAP_W / 2.0)
		_predicted_pos.y = clamp(_predicted_pos.y, -MAP_H / 2.0, MAP_H / 2.0)
		var render_pos = _predicted_pos.lerp(target, 0.25)
		player.global_position = render_pos
		player.hp = float(self_entry.hp)
		player.max_hp = float(self_entry.mhp)
		if self_entry.has("wp"):
			_mirror_build(self_entry)
	# 相机跟随本端化身
	camera.global_position = camera.global_position.lerp(player.global_position, min(1.0, delta * 8.0))

## 客机：把 host 广播的共享 build 镜像到本端化身（武器 + 等级 + 进化），保持视觉一致
func _mirror_build(entry) -> void:
	var wp = entry["wp"]
	for w in wp:
		var wid = w.id
		var lv = int(w.level)
		if not player.weapons.has(wid):
			player._equip_weapon(wid, lv)
		elif player.weapons[wid].level != lv:
			player.weapons[wid].level = lv
			player.weapons[wid].node.on_level_up(lv)
		# 进化同步（客机视觉与主机一致）
		if w.get("ev", 0) == 1 and player.weapons.has(wid) and not player.weapons[wid].node.evolved:
			player.weapons[wid].node.evolve()

## 按 pid 取一个区分度高的玩家颜色（身份环用）
func _pid_color(pid: int) -> Color:
	var palette = [
		Color(0.45, 0.8, 1.0),
		Color(1.0, 0.5, 0.4),
		Color(0.6, 1.0, 0.5),
		Color(1.0, 0.9, 0.4),
		Color(0.9, 0.5, 1.0)
	]
	return palette[pid % palette.size()]

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_N:
			if net_panel != null:
				net_panel.visible = not net_panel.visible
