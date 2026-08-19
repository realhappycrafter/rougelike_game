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
const EnemyProjectileScript = preload("res://scripts/entities/enemy_projectile.gd")
const ChestScript      = preload("res://scripts/entities/chest.gd")
const UIScript         = preload("res://scripts/ui.gd")
const BGFloorScript    = preload("res://scripts/systems/bg_floor.gd")
const RemoteWorldScript = preload("res://scripts/systems/remote_world.gd")
const NetSerializeScript = preload("res://scripts/systems/net_serialize.gd")
const UITheme = preload("res://ui_theme.tres")

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
var _game_started = false    # 是否已真正开局（选完模式后才置 true，用于 N 键与重复开局防护）

var projectile_pool = []
var enemy_projectile_pool = []   # 敌弹对象池（远程怪弹幕）
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

# 短局模式时间线（与长局 phases 并行的一套简单计时）
var short_t = 0.0
var short_boss_spawned = false
var short_boss_at = 240.0
var short_end_at = 300.0
var _sel_mode = "long"        # 大厅当前选中的模式：long / short
var _b_long = null
var _b_short = null
var _short_prog_label = null

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

## 无头自动开局（职业系统校验用）：命令行 `--class=<id>` 时跳过菜单直接进入单人局
func _cli_class() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--class="):
			var id = a.substr(8)
			if DataTables.characters.has(id):
				return id
			push_warning("[main] 命令行职业 id 不存在：" + id)
	return ""

## 无头运行校验开关：命令行 `--selftest` 时，开局后自动跑职业系统断言并退出（CI 用）
func _cli_selftest() -> bool:
	for a in OS.get_cmdline_user_args():
		if a == "--selftest":
			return true
	return false

## 无头职业系统断言：覆盖 projectile/orbit/aura 三类新 shape 的 fire 路径、
## 治愈师光环 heal_self、盾卫 guard 减伤、专属武器 on_level_up 与升级池职业过滤。
## 无头不跑 _draw（绘制正确性需人工核对）；本函数只防运行期 SCRIPT ERROR 与逻辑错误。
func _headless_selftest() -> void:
	var cid = GameManager.player_class
	var p = GameManager.player
	if p == null:
		printerr("[selftest] 职业 %s 未生成玩家" % cid)
		get_tree().quit(1)
		return
	print("[selftest] 职业 %s 开局成功，专属武器=%s" % [cid, p.class_weapon])

	# 放几个敌人供武器命中（覆盖 projectile 命中 / aura / orbit 结算）
	for k in range(6):
		EnemyManager.spawn("normal", p.global_position + Vector2(randf() * 240.0 - 120.0, randf() * 240.0 - 120.0), 1.0)
	print("[selftest] spawn ok")

	# 升级专属武器若干次：exercise on_level_up / orbit 重建 / 强化词条数值
	var wid = p.class_weapon if p.class_weapon != "" else "knife"
	for i in range(6):
		p.apply_upgrade({"type": "weapon", "id": wid})
		await get_tree().process_frame
	print("[selftest] upgrade ok")

	# 持续开火 ~3 秒：武器 fire + 治愈师治疗 + 盾卫减伤路径
	print("[selftest] before timer")
	for i in range(180):
		await get_tree().process_frame
	print("[selftest] after timer")

	# 减伤路径（盾卫 guard / 通用护甲）
	if cid == "guardian":
		p.god_mode = false
		var hp0 = p.hp
		var eg = p.effective_guard()
		p.take_damage(80.0)
		var dropped = hp0 - p.hp
		if dropped >= 80.0:
			printerr("[selftest] %s 盾卫减伤未生效 guard=%.3f 实扣=%.1f" % [cid, eg, dropped])
			get_tree().quit(1)
			return
		print("[selftest] %s 减伤生效 guard=%.3f 实扣=%.1f" % [cid, eg, dropped])
	elif cid == "healer":
		# 先受伤，再以「受伤后」血量为基准；等待期间重新开启免伤以隔离敌人干扰（治疗不受 god 影响）
		p.god_mode = false
		p.take_damage(40.0)
		var hp_low = p.hp
		p.god_mode = true
		await get_tree().create_timer(3.0).timeout
		if p.hp <= hp_low:
			printerr("[selftest] %s 治愈师光环未回血 hp_low=%f hp=%f" % [cid, hp_low, p.hp])
			get_tree().quit(1)
			return
		print("[selftest] %s 治愈师回血 %f -> %f" % [cid, hp_low, p.hp])

	# 三选一职业过滤：生成选项不应含其他职业武器（default 不限）
	if cid != "default":
		print("[selftest] before pool")
		var opts = UpgradePool.generate(p)
		for o in opts:
			if str(o.get("type", "")) == "weapon":
				var oc = str(DataTables.weapons.get(str(o.get("id", "")), {}).get("class", ""))
				if oc != "" and oc != cid:
					printerr("[selftest] %s 三选一出现其他职业武器 %s" % [cid, str(o.get("id", ""))])
					get_tree().quit(1)
					return
		print("[selftest] after pool")

	# ---- 新机制断言：护盾穿透 / 远程开火 / 自爆（不依赖职业，所有 --class 都跑）----
	# 临时免伤，隔离机制验证与玩家存活/对局结束的耦合（信号与结算仍正常触发）
	p.god_mode = true

	# 1) 护盾穿透拆分：pen=0 全打盾；pen=0.8 的 80% 直接打血、其余扣盾；pen=1 无视盾
	var suid = EnemyManager.spawn("shielded", p.global_position + Vector2(120, 0), 1.0)
	var se = EnemyManager.get_enemy(suid)
	if se.is_empty():
		printerr("[selftest] 护盾怪 shielded 生成失败")
		get_tree().quit(1); return
	var shield0 = se.shield
	var hp0 = se.hp
	EnemyManager.take_damage(suid, 10.0, Vector2.ZERO, 0.0, null, 0.0)
	se = EnemyManager.get_enemy(suid)
	if not (abs(se.shield - (shield0 - 10.0)) < 0.01) or not (abs(se.hp - hp0) < 0.01):
		printerr("[selftest] 护盾穿透(pen=0) 错误：盾=%f(期望%f) 血=%f(期望%f)" % [se.shield, shield0 - 10.0, se.hp, hp0])
		get_tree().quit(1); return
	EnemyManager.take_damage(suid, 10.0, Vector2.ZERO, 0.0, null, 0.8)
	se = EnemyManager.get_enemy(suid)
	if not (abs(se.hp - (hp0 - 8.0)) < 0.01) or not (abs(se.shield - (shield0 - 12.0)) < 0.01):
		printerr("[selftest] 护盾穿透(pen=0.8) 错误：血=%f(期望%f) 盾=%f(期望%f)" % [se.hp, hp0 - 8.0, se.shield, shield0 - 12.0])
		get_tree().quit(1); return
	EnemyManager.take_damage(suid, 9999.0, Vector2.ZERO, 0.0, null, 1.0)
	print("[selftest] 护盾穿透拆分正确（pen0 全盾 / pen0.8 血8盾2 / pen1 无视盾）")

	# 2) 远程怪开火：在玩家附近放置 caster，跑若干帧应触发 enemy_fire（host 权威生成敌弹）
	#     用 Dictionary 持有标志，规避 GDScript lambda 对局部 bool 的按值捕获问题
	var fire_flag = {"hit": false}
	var cb_fire = func(_a, _b, _c, _d, _e): fire_flag.hit = true
	EnemyManager.enemy_fire.connect(cb_fire)
	var cuid = EnemyManager.spawn("caster", p.global_position + Vector2(140, 0), 1.0)
	for i in range(200):
		await get_tree().process_frame
	EnemyManager.enemy_fire.disconnect(cb_fire)
	if not fire_flag.hit:
		printerr("[selftest] 远程怪 caster 未触发开火（enemy_fire 未发出）")
		get_tree().quit(1); return
	EnemyManager.despawn_uid(cuid)
	print("[selftest] 远程怪开火正常")

	# 3) 自爆怪：贴近玩家后应引爆，触发 enemy_explode（AoE 对范围内玩家结算 + 特效）
	var boom_flag = {"hit": false}
	var cb_boom = func(_a, _b, _c): boom_flag.hit = true
	EnemyManager.enemy_explode.connect(cb_boom)
	EnemyManager.spawn("bomber", p.global_position + Vector2(40, 0), 1.0)
	for i in range(60):
		await get_tree().process_frame
	EnemyManager.enemy_explode.disconnect(cb_boom)
	if not boom_flag.hit:
		printerr("[selftest] 自爆怪 bomber 未触发爆炸（enemy_explode 未发出）")
		get_tree().quit(1); return
	print("[selftest] 自爆怪引爆正常")

	# ---- 词条系统断言（质变 / 超质变 / 怪物黑词条 / 商店刷新 / 三选一注入）----
	# 1) 武器质变 -> 超质变：damage_mult 累乘；超质变需先有前置质变
	p.apply_upgrade({"type":"affix", "affix_id":"knife_mut", "category":"weapon", "require_weapon":"knife"})
	var wm = AffixManager.weapon_mods("knife")
	if abs(wm.damage_mult - 1.15) > 0.01:
		printerr("[selftest] 武器质变 damage_mult 错误：%f（期望1.15）" % wm.damage_mult)
		get_tree().quit(1); return
	p.apply_upgrade({"type":"affix", "affix_id":"knife_sup", "category":"weapon", "require_weapon":"knife"})
	wm = AffixManager.weapon_mods("knife")
	if abs(wm.damage_mult - 1.495) > 0.01:
		printerr("[selftest] 武器超质变 damage_mult 错误：%f（期望1.495）" % wm.damage_mult)
		get_tree().quit(1); return
	# 2) 玩家质变：经 apply_upgrade 真实路径施加到玩家字段（ply_power_mut +15% 伤害）
	p.apply_upgrade({"type":"affix", "affix_id":"ply_power_mut", "category":"player", "require_weapon":""})
	if abs(p.damage_bonus - 0.15) > 0.01:
		printerr("[selftest] 玩家质变 damage_bonus 未施加：%f（期望0.15）" % p.damage_bonus)
		get_tree().quit(1); return
	# 3) 怪物黑词条：聚合 monster_player_debuffs 正确（m_curse -12% 玩家伤害）
	AffixManager.add_monster_affix("m_curse")
	var db = AffixManager.monster_player_debuffs()
	if abs(db.damage_mult - 0.88) > 0.01:
		printerr("[selftest] 怪物黑词条 damage_mult 错误：%f（期望0.88）" % db.damage_mult)
		get_tree().quit(1); return
	AffixManager.apply_monster_debuffs(p)   # 施加削弱，验证玩家字段被改（此处应已×0.88）
	# 4) 商店刷新：成本随刷新次数递增
	AffixManager.rebuild_affix_stock(p)
	var c0 = AffixManager.refresh_cost()
	AffixManager.shop_refresh_count += 1
	var c1 = AffixManager.refresh_cost()
	if not (c1 > c0):
		printerr("[selftest] 商店刷新成本未递增：%d -> %d" % [c0, c1])
		get_tree().quit(1); return
	# 5) 三选一注入不崩溃（含可能出现的质变/超质变）
	var opts2 = UpgradePool.generate(p)
	print("[selftest] 三选一生成 %d 项（含可能词条）" % opts2.size())

	print("[selftest] 职业 %s 运行无致命错误" % cid)
	get_tree().quit(0)

func _ready():
	# 选图优先级：命令行 `-- --map=<id>`（调试/无头验证） > 菜单已选 > 默认地图
	var forced_map = _cli_map()
	if forced_map != "":
		GameManager.set_map(forced_map)
	elif GameManager.current_map.is_empty():
		GameManager.set_map(GameManager.map_id)

	# 屏幕空间 UI 层（HUD 与联机面板都挂这里，隔离相机滚动）
	ui_layer = CanvasLayer.new()
	add_child(ui_layer)
	ui = Control.new()
	ui.set_script(UIScript)
	ui_layer.add_child(ui)

	# ---- 联机接入层：先弹「开始方式」面板，玩家选完模式再真正开局 ----
	# 满足需求：是否联机选完再开始游戏（世界 / 敌人模拟延迟到 _start_game 才构建）。
	GameManager.combat_players = []
	GameManager.playing = false
	_game_started = false
	NetManager.connect("connected_changed", _on_net_connected_changed)
	NetManager.connect("message_received", _on_net_message)
	_build_net_panel()
	net_panel.visible = true

	# 无头自动开局：--class=<id> 时跳过菜单，直接进入单人局（用于职业系统无头校验）
	var forced_class = _cli_class()
	if forced_class != "":
		GameManager.set_player_class(forced_class)
		call_deferred("_on_choose_solo")
		if _cli_selftest():
			call_deferred("_headless_selftest")

## 真正开局：构建世界 / 玩家 / 敌人并启动一局。仅在玩家选定模式（单机 / 主机 / 客机）后调用，
## 解决「是否联机选完再开始游戏」——在此之前世界不构建、run 不启动、对局不计时。
func _start_game() -> void:
	if _game_started:
		return
	_game_started = true
	# 一旦选定模式即收起「开始方式」联机面板：否则带黑词条三选一（普通及以上难度）
	# 会先走 _start_affix_draft 分支，net_panel 要等三选一结束才在 _begin_run_mode 隐藏，
	# 期间全屏 MOUSE_FILTER_STOP 的面板会盖住词条面板、卡死所有点击（表现为「联机面板未消失」）。
	if net_panel != null:
		net_panel.visible = false

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
	# 远程怪弹幕 / 自爆怪爆炸：host 端模拟，信号接到主场景做敌弹生成与 AoE 结算
	if not EnemyManager.is_connected("enemy_fire", _on_enemy_fire):
		EnemyManager.connect("enemy_fire", _on_enemy_fire)
	if not EnemyManager.is_connected("enemy_explode", _on_enemy_explode):
		EnemyManager.connect("enemy_explode", _on_enemy_explode)

	# 信号连接
	GameManager.connect("level_up_requested", _on_level_up_requested)
	GameManager.connect("run_ended", _on_run_ended)
	GameManager.connect("hud_changed", _on_hud_changed)
	ui.connect("option_selected", _on_option_chosen)
	ui.connect("restart_requested", _on_restart)
	ui.connect("shop_requested", _on_shop_requested)

	SpawnManager.reset()
	ui.init_hud()
	GameManager.start_run(world, player, GameManager.game_mode, GameManager.short_world, GameManager.short_stage)
	# 阶段机：长局按地图多阶段；短局按单一计时（4 分刷 Boss、5 分强制结束）
	if GameManager.game_mode == "short":
		_init_short_run()
	else:
		init_run_phases()
	if GameManager.difficulty_id == "extreme":
		ui.show_perf_warning("⚠ 极端模式：敌人数量极多，低端设备可能出现卡顿")
	player.setup_character(DataTables.characters["default"] if not DataTables.characters.has(GameManager.player_class) else DataTables.characters[GameManager.player_class])
	# 局外强化（meta_upgrades）叠加到基础属性
	player.apply_meta_upgrades(SaveManager.get_meta_upgrades())
	# 无头长时程测试：--god 免伤，覆盖 Boss/通关分支
	if _cli_god():
		player.god_mode = true
		push_warning("[main] 无头测试免伤模式已启用（--god）")
	# 开场旁白（诸天万界世界观）：短局用专属分段剧情，长局用世界总剧情
	var m = GameManager.current_map
	if GameManager.game_mode == "short" and m.has("short_story") and ui != null:
		var ss = m["short_story"]
		var idx = clamp(GameManager.short_stage - 1, 0, ss.size() - 1)
		ui.show_story(m.get("world", ""), m.get("name", "未知界域") + " · 短局第 %d 局" % GameManager.short_stage, ss[idx])
	elif m.has("story_intro") and ui != null:
		ui.show_story(m.get("world", ""), m.get("name", "未知界域"), m.get("story_intro", ""))

	# 怪物黑色词条：开局前置三选一（按难度数量）。headless（含无头校验）自动选，否则弹窗交互。
	# reset_run 清空上一局全部词条状态（质变/超质变/黑词条/商店刷新）。
	AffixManager.reset_run()
	var diff_id = GameManager.difficulty_id
	var n_affix = AffixManager.monster_affix_count(diff_id)
	if _cli_selftest():
		n_affix = 0   # 无头断言保持确定性：不在 selftest 里随机注入黑词条
	if n_affix > 0 and not OS.has_feature("headless"):
		_start_affix_draft(diff_id, n_affix)
	elif n_affix > 0:
		_affix_autopick(diff_id, n_affix)
		_begin_run_mode()
	else:
		_begin_run_mode()

## ---------- 怪物黑色词条：开局前置三选一 ----------
var _draft_options: Array = []
var _draft_remaining: int = 0
var _draft_free: int = 0
var _draft_diff: String = ""
var _draft_active: bool = false

## 交互式黑色词条三选一：按难度数量逐个抽取，免费 3 次刷新后金币刷新
func _start_affix_draft(diff_id: String, n: int) -> void:
	_draft_options = []
	_draft_remaining = n
	_draft_free = 3
	_draft_diff = diff_id
	_draft_active = true
	if not ui.is_connected("monster_affix_chosen", _on_monster_affix_chosen):
		ui.connect("monster_affix_chosen", _on_monster_affix_chosen)
	if not ui.is_connected("monster_affix_reroll", _on_monster_affix_reroll):
		ui.connect("monster_affix_reroll", _on_monster_affix_reroll)
	get_tree().paused = true
	_affix_draft_next()

func _affix_draft_next() -> void:
	if _draft_remaining <= 0:
		_finish_affix_draft()
		return
	var ids = AffixManager.roll_monster_choices(_draft_diff, 3)
	_draft_options = []
	for aid in ids:
		var a = AffixManager.monster_affixes.get(aid, {})
		_draft_options.append({"id": aid, "name": a.get("name", aid), "desc": a.get("desc", "")})
	ui.show_monster_affix_draft(_draft_options, _draft_free, AffixManager.refresh_cost(), _draft_remaining)

func _on_monster_affix_chosen(idx: int) -> void:
	if idx < 0 or idx >= _draft_options.size():
		return
	var aid = str(_draft_options[idx].get("id", ""))
	if aid != "":
		AffixManager.add_monster_affix(aid)
		_draft_remaining -= 1
	ui.hide_monster_affix_draft()
	_affix_draft_next()

func _on_monster_affix_reroll() -> void:
	if _draft_free > 0:
		_draft_free -= 1
		_affix_draft_next()
	else:
		var cost = AffixManager.refresh_cost()
		if GameManager.gold >= cost:
			GameManager.gold -= cost
			AffixManager.shop_refresh_count += 1
			_affix_draft_next()
		else:
			ui.info("金币不足，无法刷新", Color(1.0, 0.5, 0.5))

func _finish_affix_draft() -> void:
	ui.hide_monster_affix_draft()
	get_tree().paused = false
	if ui.is_connected("monster_affix_chosen", _on_monster_affix_chosen):
		ui.disconnect("monster_affix_chosen", _on_monster_affix_chosen)
	if ui.is_connected("monster_affix_reroll", _on_monster_affix_reroll):
		ui.disconnect("monster_affix_reroll", _on_monster_affix_reroll)
	AffixManager.apply_monster_debuffs(player)
	_draft_active = false
	_begin_run_mode()

## headless 自动选：直接抽取 n 个黑词条并施加削弱（无头校验/长时程用）
func _affix_autopick(diff_id: String, n: int) -> void:
	var choices = AffixManager.roll_monster_choices(diff_id, n)
	for a in choices:
		AffixManager.add_monster_affix(a)
	AffixManager.apply_monster_debuffs(player)

## 进入对局模式（原 _start_game 末段：按 solo/host/guest 分支启动，隐藏联机面板）
func _begin_run_mode() -> void:
	if GameManager.net_mode == GameManager.NetMode.GUEST:
		_enter_guest_mode()
	else:
		_enter_host_mode()
	if net_panel != null:
		net_panel.visible = false
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
	if GameManager.game_mode == "short":
		_update_short_phases(delta)
	else:
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

## 短局模式初始化：单一计时线（4 分刷 1 个 Boss、5 分到点强制结束）
func _init_short_run() -> void:
	var md = DataTables.modes["short"]
	short_boss_at = float(md.get("boss_at", 240))
	short_end_at = float(md.get("duration", 300))
	short_t = 0.0
	short_boss_spawned = false
	boss_uids.clear()
	boss_defeated = false
	last_level = 0
	_unlock_announced.clear()
	SpawnManager.unlocked.clear()
	chest_timer = 0.0
	if ui != null:
		ui.set_stage(0, "survival")
		ui.info("短局模式：%d 分钟，%d 分刷 Boss！" % [int(short_end_at / 60.0), int(short_boss_at / 60.0)], Color(0.5, 0.9, 1.0))
		ui.info("第 %d 界 · %s · 短局第 %d 局" % [int(GameManager.current_map.get("order", 1)), GameManager.current_map.get("name", ""), GameManager.short_stage], Color(0.9, 0.8, 0.4))
	spawn_phase_chests(15)

## 短局阶段推进：boss_at 刷一个 Boss；end_at 到点强制结束（不论 Boss 是否死亡，标记通关）
func _update_short_phases(delta: float) -> void:
	short_t += delta
	if not short_boss_spawned and short_t >= short_boss_at:
		short_boss_spawned = true
		var bid = ""
		var phases0 = GameManager.current_map.get("phases", [])
		if phases0.size() > 0:
			bid = phases0[0].get("boss_enemy", "")
		if DataTables.enemies.has(bid):
			var uid = EnemyManager.spawn(bid, rand_spawn_pos(), GameManager.enemy_scale)
			if uid >= 0:
				boss_uids.append(uid)
			if ui != null:
				ui.info("BOSS战开启！！ " + DataTables.enemies[bid].name + " 将追杀你！", Color(1.0, 0.3, 0.3), true)
				ui.set_stage(0, "boss")
	if short_t >= short_end_at:
		if not boss_defeated:
			for uid in boss_uids:
				EnemyManager.despawn_uid(uid)
			boss_uids.clear()
			if ui != null:
				ui.info("时间到！你撑过了短局！", Color(0.8, 1.0, 0.8))
		GameManager.end_run("win")

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
		# 绿宝石特殊掉落：不论长局/短局，击杀 Boss 随机掉 1~5 颗（用于局外高级强化 / 局内高级道具）
		var ne = randi_range(1, 5)
		for i in range(ne):
			spawn_gem(snap.pos + Vector2(randf() * 70.0 - 35.0, randf() * 70.0 - 35.0), "emerald", 1)
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

## 宝箱开启回调：弹信息框（col 为本次奖励品质色，由 chest.gd 按奖励等级传入）
func on_chest_opened(desc: String, col: Color = Color(1.0, 0.85, 0.4)) -> void:
	if ui != null:
		ui.info("宝箱开启获得了 " + desc, col)

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

## 敌弹对象池（远程怪弹幕）：与玩家弹体同款复用模式
func get_enemy_projectile():
	var p
	if enemy_projectile_pool.is_empty():
		p = Area2D.new()
		p.set_script(EnemyProjectileScript)
		world.add_child(p)
	else:
		p = enemy_projectile_pool.pop_back()
		if p.get_parent() == null:
			world.add_child(p)
		p.visible = true
	return p

func return_enemy_projectile(p) -> void:
	enemy_projectile_pool.append(p)

## 远程怪开火：host 收到 EnemyManager.enemy_fire 信号后生成敌弹（仅 host 端发射，
## 与敌人接触伤害同源：host 权威，伤害统一应用到全部 combat_players 含客机代理）。
func _on_enemy_fire(epos: Vector2, edir: Vector2, espeed: float, edmg: float, ecol: Color) -> void:
	if GameManager.net_mode == GameManager.NetMode.GUEST:
		return
	var p = get_enemy_projectile()
	if p != null:
		p.launch(epos, edir, espeed, edmg, ecol, self)

## 自爆怪 / 爆炸 AoE：对范围内所有玩家结算伤害，并写入 EnemyManager.explosions
## 供 draw_enemies 画扩散光环（0.35s 衰减）。host 端触发（enemy_explode 仅 host 发出）。
func _on_enemy_explode(epos: Vector2, eradius: float, edmg: float) -> void:
	for pl in GameManager.get_players_for_combat():
		if not is_instance_valid(pl):
			continue
		if epos.distance_to(pl.global_position) <= eradius + pl.body_radius:
			pl.take_damage(edmg)
	EnemyManager.explosions.append({"pos": epos, "r": eradius, "t": 0.0})

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

## 暂停菜单「商店」按钮请求：打开局内强化商店
func _on_shop_requested() -> void:
	if ui != null:
		ui.show_shop()

# ==========================================================================
# 联机接入层（零成本：WebSocket 中继 + host 权威）
# ==========================================================================

## 构建「开始方式」面板（开局闸门，必须先选模式再开始游戏）。
## 相比旧版更大、更清晰：居中大面板 + 三种开始方式大按钮 + 房间/中继输入 + 状态提示。
func _build_net_panel() -> void:
	net_panel = Control.new()
	net_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	net_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	net_panel.theme = UITheme
	net_panel.process_mode = Node.PROCESS_MODE_ALWAYS

	# Web 导出下必须显式覆盖字体，否则自定义 CJK 字体不生效→中文变方框
	var cjk: Font = UITheme.default_font

	# 全屏半透明遮罩（面板之外变暗，聚焦选择）
	var dim = ColorRect.new()
	dim.color = Color(0.02, 0.02, 0.05, 0.86)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	net_panel.add_child(dim)

	# 居中大面板（按视口自适应，设上下限避免极端尺寸）
	var pw = 600.0
	var ph = 620.0
	var vsize = get_viewport_rect().size
	pw = min(pw, vsize.x - 40.0)
	ph = min(ph, vsize.y - 40.0)
	var panel = Panel.new()
	panel.name = "LobbyPanel"
	panel.custom_minimum_size = Vector2(pw, ph)
	panel.size = Vector2(pw, ph)
	panel.position = vsize / 2.0 - panel.size / 2.0
	net_panel.add_child(panel)

	var pad = 30.0
	var vbox = VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("margin_left", pad)
	vbox.add_theme_constant_override("margin_right", pad)
	vbox.add_theme_constant_override("margin_top", pad)
	vbox.add_theme_constant_override("margin_bottom", pad)
	vbox.add_theme_constant_override("separation", 16)
	panel.add_child(vbox)

	var title = Label.new()
	title.text = "开始游戏"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 34)
	title.add_theme_font_override("font", cjk)
	vbox.add_child(title)

	var subtitle = Label.new()
	subtitle.text = "请选择模式与开始方式（联机采用零成本 WebSocket 中继）"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 16)
	subtitle.add_theme_color_override("font_color", Color(0.7, 0.75, 0.85))
	subtitle.add_theme_font_override("font", cjk)
	vbox.add_child(subtitle)

	# 模式选择：长局(20分) / 短局(5分)
	var mode_row = HBoxContainer.new()
	mode_row.alignment = BoxContainer.ALIGNMENT_CENTER
	mode_row.add_theme_constant_override("separation", 16)
	vbox.add_child(mode_row)
	_b_long = Button.new()
	_b_long.text = "长局 · 20 分钟"
	_b_long.add_theme_font_override("font", cjk)
	_b_long.add_theme_font_size_override("font_size", 20)
	_b_long.custom_minimum_size = Vector2(220, 50)
	_b_long.connect("pressed", func(): _set_sel_mode("long"))
	mode_row.add_child(_b_long)
	_b_short = Button.new()
	_b_short.text = "短局 · 5 分钟"
	_b_short.add_theme_font_override("font", cjk)
	_b_short.add_theme_font_size_override("font_size", 20)
	_b_short.custom_minimum_size = Vector2(220, 50)
	_b_short.connect("pressed", func(): _set_sel_mode("short"))
	mode_row.add_child(_b_short)

	_short_prog_label = Label.new()
	_short_prog_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_short_prog_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_short_prog_label.add_theme_font_size_override("font_size", 14)
	_short_prog_label.add_theme_color_override("font_color", Color(0.6, 0.9, 0.7))
	_short_prog_label.add_theme_font_override("font", cjk)
	vbox.add_child(_short_prog_label)
	_set_sel_mode(_sel_mode)   # 初始化高亮 + 进度文案

	var b_solo = Button.new()
	b_solo.text = "单人游戏（跳过联机）"
	b_solo.add_theme_font_override("font", cjk)
	b_solo.add_theme_font_size_override("font_size", 22)
	b_solo.custom_minimum_size = Vector2(0, 56)
	vbox.add_child(b_solo)

	var b_host = Button.new()
	b_host.text = "创建房间（主机 / 权威）"
	b_host.add_theme_font_override("font", cjk)
	b_host.add_theme_font_size_override("font_size", 22)
	b_host.custom_minimum_size = Vector2(0, 56)
	vbox.add_child(b_host)

	var b_guest = Button.new()
	b_guest.text = "加入房间（客机）"
	b_guest.add_theme_font_override("font", cjk)
	b_guest.add_theme_font_size_override("font_size", 22)
	b_guest.custom_minimum_size = Vector2(0, 56)
	vbox.add_child(b_guest)

	var tip = Label.new()
	tip.text = "第一个进房者为主机（权威），其余为客机。同一房间内等级 / 金币 / 升级全局共享。"
	tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tip.add_theme_font_size_override("font_size", 14)
	tip.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	tip.add_theme_font_override("font", cjk)
	vbox.add_child(tip)

	var room_le = LineEdit.new()
	room_le.placeholder_text = "房间名（如 room1）"
	room_le.text = "room1"
	room_le.custom_minimum_size = Vector2(0, 42)
	room_le.add_theme_font_override("font", cjk)
	vbox.add_child(room_le)

	var url_le = LineEdit.new()
	url_le.placeholder_text = "中继地址 ws://host:port"
	url_le.text = _default_relay_url()
	url_le.custom_minimum_size = Vector2(0, 42)
	url_le.add_theme_font_override("font", cjk)
	vbox.add_child(url_le)

	var status = Label.new()
	status.name = "Status"
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status.add_theme_font_size_override("font_size", 15)
	status.add_theme_color_override("font_color", Color(0.5, 0.9, 0.7))
	status.add_theme_font_override("font", cjk)
	vbox.add_child(status)

	b_solo.connect("pressed", _on_choose_solo)
	b_host.connect("pressed", func(): _on_choose_host(room_le.text, url_le.text))
	b_guest.connect("pressed", func(): _on_choose_guest(room_le.text, url_le.text))

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

## 选择「单人游戏」：直接进入本地一局（不连中继）
func _on_choose_solo() -> void:
	GameManager.net_mode = GameManager.NetMode.SOLO
	if _sel_mode == "short":
		_prepare_short()
	GameManager.game_mode = _sel_mode
	_start_game()

## 选择「创建房间」：以主机身份连接中继，连上后再真正开局
func _on_choose_host(room: String, url: String) -> void:
	GameManager.net_mode = GameManager.NetMode.HOST
	if _sel_mode == "short":
		_prepare_short()
	GameManager.game_mode = _sel_mode
	NetManager.connect_relay(url, room, true)
	_set_status("正在创建房间「%s」并连接…" % room)

## 选择「加入房间」：以客机身份连接中继，连上后再真正开局
func _on_choose_guest(room: String, url: String) -> void:
	GameManager.net_mode = GameManager.NetMode.GUEST
	if _sel_mode == "short":
		_prepare_short()
	GameManager.game_mode = _sel_mode
	NetManager.connect_relay(url, room, false)
	_set_status("正在加入房间「%s」…" % room)

## 切换大厅选中模式（长局 / 短局），刷新高亮与短局进度文案
func _set_sel_mode(mode: String) -> void:
	_sel_mode = mode
	if _b_long != null:
		_b_long.disabled = (mode == "long")
		_b_long.add_theme_color_override("font_color", Color(1, 1, 1, 1) if mode == "long" else Color(0.6, 0.65, 0.75))
	if _b_short != null:
		_b_short.disabled = (mode == "short")
		_b_short.add_theme_color_override("font_color", Color(1, 1, 1, 1) if mode == "short" else Color(0.6, 0.65, 0.75))
	_refresh_short_prog()

func _refresh_short_prog() -> void:
	if _short_prog_label == null:
		return
	if _sel_mode != "short":
		_short_prog_label.text = "短局：每世界 3 局，需【长局+短局都通关】才解锁下一界（Boss 掉落绿宝石）"
		_short_prog_label.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
		return
	var nxt = SaveManager.short_next()
	if nxt.is_empty():
		# 没有可推进的短局：可能是「全部已通关」，也可能是卡在「长局未通关」门槛
		var need_long = false
		var ids = DataTables.maps.keys()
		ids.sort_custom(func(a, b): return int(DataTables.maps[a].get("order", 99)) < int(DataTables.maps[b].get("order", 99)))
		for mid in ids:
			if not SaveManager.is_map_unlocked(mid):
				need_long = true
				break
			if not SaveManager.short_world_cleared(mid):
				break
		if need_long:
			_short_prog_label.text = "短局进度：本世界短局已全通，需先通关对应【长局】才能解锁下一界。"
		else:
			_short_prog_label.text = "短局进度：全部世界已通关！可重复挑战最后世界第 3 局。"
		return
	var w = DataTables.maps.get(nxt.world, {})
	_short_prog_label.text = "短局进度：下一局 → 第%s界·%s 第 %d 局 / 3" % [str(w.get("order", "?")), str(w.get("name", nxt.world)), int(nxt.stage)]

## 短局：确定本局世界与第几局（取下一个未通关的短局；全通后允许重复最后世界）
func _prepare_short() -> void:
	var nxt = SaveManager.short_next()
	if nxt.is_empty():
		var ids = DataTables.maps.keys()
		ids.sort_custom(func(a, b): return int(DataTables.maps[a].get("order", 99)) < int(DataTables.maps[b].get("order", 99)))
		var last = ids[ids.size() - 1] if not ids.is_empty() else "zombie"
		nxt = {"world": last, "stage": 3}
	GameManager.short_world = nxt.world
	GameManager.short_stage = int(nxt.stage)
	GameManager.set_map(nxt.world)

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
		if not _game_started:
			# 首次连接：此刻才真正构建世界并进入对应模式（满足「选完再开始游戏」）
			_start_game()
		else:
			# 对局中按 N 重新选择模式：仅切换联机身份，不重建世界
			if GameManager.net_mode == GameManager.NetMode.GUEST:
				_enter_guest_mode()
			else:
				_enter_host_mode()
		if net_panel != null:
			net_panel.visible = false
	else:
		_set_status("连接已断开，可重新选择模式")
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
	rp.setup_character(DataTables.characters["default"] if not DataTables.characters.has(GameManager.player_class) else DataTables.characters[GameManager.player_class])
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
			# 仅开局后允许用 N 开关联机面板；开局前面板是「开始方式」闸门，不响应 N
			if _game_started and net_panel != null:
				net_panel.visible = not net_panel.visible
		elif event.keycode == KEY_B:
			# B 键开关局内强化商店（暂停态打开，避免与升级/结算面板冲突）
			if _game_started and ui != null:
				ui.toggle_shop()
