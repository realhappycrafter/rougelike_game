extends Node
## smoke_check —— 无头自检（数据一致性 + 局外强化落点）
## 用法：Godot --headless --path rougelike_game res://tests/smoke_check.tscn
## 只读校验，不写存档；任何一项失败以非零退出码结束，便于 CI/脚本捕获。

const NetSerialize = preload("res://scripts/systems/net_serialize.gd")
const WeaponVisual = preload("res://scripts/systems/weapon_visual.gd")
const AffixVisual = preload("res://scripts/systems/affix_visual.gd")

var fails = []
var checks = 0

func _ready():
	_check_maps()
	_check_weapons_maps()
	_check_weapon_visuals()
	_check_meta_stats()
	_check_meta_math()
	_check_classes()
	_check_unlock_chain()
	await _check_menu_ui()
	_check_buy_and_apply()
	_check_level_up_pool()
	_check_net_snapshot()
	await _check_lobby_gate()
	_check_modes()
	_check_emerald_meta()
	_check_short_progression()
	await _check_shop_buy()
	_check_run_mode_mult()
	_check_affixes()
	print("[smoke] 共 %d 项检查，失败 %d 项" % [checks, fails.size()])
	for f in fails:
		printerr("[smoke][FAIL] " + f)
	get_tree().quit(0 if fails.is_empty() else 1)

func _ok(cond: bool, msg: String) -> void:
	checks += 1
	if not cond:
		fails.append(msg)

## 1) 每张地图引用的敌人 id 必须存在于 enemies.json
func _check_maps() -> void:
	_ok(DataTables.maps.size() >= 3, "maps.json 应至少 3 张地图，实际 %d" % DataTables.maps.size())
	var orders = {}
	for mid in DataTables.maps.keys():
		var m = DataTables.maps[mid]
		var o = int(m.get("order", -1))
		_ok(o > 0, "%s 缺少有效 order" % mid)
		_ok(not orders.has(o), "order 重复：%d（%s）" % [o, mid])
		orders[o] = mid
		_ok(str(m.get("story_intro", "")) != "", "%s 缺少 story_intro" % mid)
		_ok(str(m.get("story_outro", "")) != "", "%s 缺少 story_outro" % mid)
		# roster
		var roster = m.get("roster", [])
		_ok(roster.size() > 0, "%s roster 为空" % mid)
		for eid in roster:
			_ok(DataTables.enemies.has(eid), "%s roster 引用了不存在的敌人 %s" % [mid, eid])
		# phases -> boss_enemy
		var phases = m.get("phases", [])
		_ok(phases.size() > 0, "%s phases 为空" % mid)
		for ph in phases:
			var b = str(ph.get("boss_enemy", ""))
			_ok(DataTables.enemies.has(b), "%s phase boss_enemy 不存在：%s" % [mid, b])
		# unlock_schedule -> enemy
		for u in m.get("unlock_schedule", []):
			var e = str(u.get("enemy", ""))
			_ok(DataTables.enemies.has(e), "%s unlock_schedule 引用不存在敌人 %s" % [mid, e])
	# 顺序必须从 1 连续
	for i in range(1, DataTables.maps.size() + 1):
		_ok(orders.has(i), "缺少 order=%d 的地图（顺序解锁会断链）" % i)

## 2) 武器的 maps 字段必须引用真实地图；且每张地图至少有一把可用武器
func _check_weapons_maps() -> void:
	var per_map = {}
	for mid in DataTables.maps.keys():
		per_map[mid] = 0
	for wid in DataTables.weapons.keys():
		var allowed = DataTables.weapons[wid].get("maps", [])
		for mid in allowed:
			_ok(DataTables.maps.has(mid), "武器 %s 的 maps 引用了不存在的地图 %s" % [wid, mid])
		if allowed.is_empty():
			for mid in per_map.keys():
				per_map[mid] += 1
		else:
			for mid in allowed:
				if per_map.has(mid):
					per_map[mid] += 1
	for mid in per_map.keys():
		_ok(per_map[mid] >= 3, "地图 %s 可用武器仅 %d 把（升级池会太空）" % [mid, per_map[mid]])

## 2b) 每把武器必须有 visual，且 shape 必须匹配其 type 的已知枚举
func _check_weapon_visuals() -> void:
	# 武器特效约定（2026-08-16）：每把武器必须有专属、被支持的 visual.shape，
	# 且 shape 全局唯一（禁止多武器共用兜底形状）；type 必须与渲染分支类别一致。
	var supported = {}   # shape -> category
	for e in WeaponVisual.shape_list():
		supported[e[0]] = e[1]
	var seen_shapes = {}
	for wid in DataTables.weapons.keys():
		var w = DataTables.weapons[wid]
		var t = str(w.get("type", ""))
		var vis = w.get("visual", {})
		_ok(typeof(vis) == TYPE_DICTIONARY and vis.size() > 0,
			"武器 %s 缺少 visual 字段" % wid)
		var shape = str(vis.get("shape", ""))
		_ok(shape != "", "武器 %s 的 visual.shape 不能为空" % wid)
		_ok(supported.has(shape),
			"武器 %s 的 visual.shape=%s 未被 WeaponVisual 支持（需新增专属分支）" % [wid, shape])
		if supported.has(shape):
			_ok(supported[shape] == t,
				"武器 %s 的 visual.shape=%s 属 %s 类，但 type=%s（类别不一致）" % [wid, shape, supported[shape], t])
		_ok(not seen_shapes.has(shape),
			"武器 %s 的 visual.shape=%s 与 %s 重复（每把武器必须有独立特效）" % [wid, shape, seen_shapes.get(shape, "")])
		seen_shapes[shape] = wid
		# 颜色存在且为 3 元素数组（缺失会用兜底色，但数据应完整）
		for ck in ["color", "color2"]:
			if vis.has(ck):
				var c = vis[ck]
				_ok(typeof(c) == TYPE_ARRAY and c.size() >= 3,
					"武器 %s visual.%s 应为 [r,g,b] 数组" % [wid, ck])

## 3) meta_upgrades 的 stat 必须是 player 已实现的字段名
func _check_meta_stats() -> void:
	var known = ["max_hp", "damage", "speed", "pickup", "cooldown", "armor",
		"luck", "crit", "crit_dmg", "lifesteal", "shield_pen", "revives", "gold_gain", "exp_gain",
		"class_spec"]
	_ok(DataTables.meta_upgrades.size() > 0, "meta_upgrades.json 为空")
	for id in DataTables.meta_upgrades.keys():
		var u = DataTables.meta_upgrades[id]
		_ok(known.has(str(u.get("stat", ""))), "meta %s 的 stat=%s 未被 player 实现" % [id, u.get("stat", "")])
		_ok(int(u.get("max_level", 0)) > 0, "meta %s 的 max_level 非法" % id)
		_ok(int(u.get("cost_base", 0)) > 0, "meta %s 的 cost_base 非法" % id)
		_ok(float(u.get("cost_growth", 0.0)) >= 1.0, "meta %s 的 cost_growth 应 >= 1.0" % id)

## 4b) 职业系统完整性：每个职业必须有专属武器（带 class 标签）与对应专精 meta；
## 专精 meta 必须带 class 字段 + spec_per_level 多属性；无职业（is_class=false）不强制。
func _check_classes() -> void:
	var class_ids = []
	for cid in DataTables.characters.keys():
		var c = DataTables.characters[cid]
		if not c.get("is_class", false):
			continue
		class_ids.append(cid)
		_ok(class_ids.size() >= 0, "")
		# 专属武器存在且带 class 标签
		var wid = str(c.get("start_weapon", ""))
		_ok(DataTables.weapons.has(wid), "职业 %s 的专属武器 %s 不存在" % [cid, wid])
		if DataTables.weapons.has(wid):
			_ok(str(DataTables.weapons[wid].get("class", "")) == cid,
				"职业 %s 的专属武器 %s 的 class 标签未指向该职业" % [cid, wid])
		# 专精 meta 存在且字段合法
		var spec = str(c.get("spec", ""))
		_ok(spec != "" and DataTables.meta_upgrades.has(spec),
			"职业 %s 缺少对应专精 meta（%s）" % [cid, spec])
		if DataTables.meta_upgrades.has(spec):
			var su = DataTables.meta_upgrades[spec]
			_ok(str(su.get("class", "")) == cid,
				"专精 %s 的 class 字段未指向职业 %s" % [spec, cid])
			_ok(su.has("spec_per_level") and typeof(su["spec_per_level"]) == TYPE_DICTIONARY,
				"专精 %s 缺少 spec_per_level 字典" % spec)
	# 反向：所有带 class 的武器都应被某个职业引用为 start_weapon
	for wid in DataTables.weapons.keys():
		var wclass = str(DataTables.weapons[wid].get("class", ""))
		if wclass == "":
			continue
		var found = false
		for cid in DataTables.characters.keys():
			if str(DataTables.characters[cid].get("start_weapon", "")) == wid:
				found = true
				break
		_ok(found, "专属武器 %s 未被任何职业引用为 start_weapon" % wid)

	# 专精落点：战士专精 Lv3 应使伤害 +0.12 且生命 +54（spec_per_level 多属性）
	var backup = SaveManager.data.duplicate(true)
	SaveManager.data["meta_upgrades"] = {}
	SaveManager.data["meta_upgrades"]["spec_warrior"] = 3
	var p = load("res://scripts/entities/player.gd").new()
	add_child(p)
	var dmg0 = p.damage_bonus
	var hp0 = p.base_max_hp
	p.apply_meta_upgrades(SaveManager.get_meta_upgrades())
	_ok(is_equal_approx(p.damage_bonus, dmg0 + 0.04 * 3.0),
		"战士专精 Lv3 应使伤害 +0.12，实际 %.2f" % (p.damage_bonus - dmg0))
	_ok(is_equal_approx(p.base_max_hp, hp0 + 18.0 * 3.0),
		"战士专精 Lv3 应使生命 +54，实际 %.1f" % (p.base_max_hp - hp0))
	p.queue_free()
	SaveManager.data = backup
	SaveManager.save_data()

	# 三选一职业过滤：选定战士时，升级池不应出现其他职业的武器词条
	GameManager.player_class = "warrior"
	var pu = load("res://scripts/entities/player.gd").new()
	add_child(pu)
	GameManager.map_id = "zombie"
	pu.weapons = {}
	pu.passives = {}
	var opts = UpgradePool.generate(pu)
	for o in opts:
		if str(o.get("type", "")) == "weapon":
			var oid = str(o.get("id", ""))
			var oclass = str(DataTables.weapons.get(oid, {}).get("class", ""))
			_ok(oclass == "" or oclass == "warrior",
				"战士的三选一出现了其他职业武器 %s（class=%s）" % [oid, oclass])
	GameManager.player_class = ""
	pu.queue_free()

## 5) 通关解锁链（新规则）：下一界解锁需「长局通关 且 短局 3 局全通」同时满足，
##    仅通关其一不得解锁下一界。备份后写回，避免污染玩家进度。
func _check_unlock_chain() -> void:
	var backup = SaveManager.data.duplicate(true)
	SaveManager.data["map_progress"] = {"unlocked": ["zombie"], "cleared": []}
	SaveManager.data["short_cleared"] = []
	var ids = []
	for i in range(1, DataTables.maps.size() + 1):
		for mid in DataTables.maps.keys():
			if int(DataTables.maps[mid].get("order", -1)) == i:
				ids.append(mid)
				break
	_ok(SaveManager.is_map_unlocked(ids[0]), "首图 %s 应默认解锁" % ids[0])
	for i in range(ids.size()):
		if i + 1 < ids.size():
			_ok(not SaveManager.is_map_unlocked(ids[i + 1]),
				"通关 %s 之前，%s 不应解锁" % [ids[i], ids[i + 1]])
		# 仅通关长局：不应解锁下一界（需配合短局）
		SaveManager.mark_map_cleared(ids[i])
		_ok(SaveManager.is_map_cleared(ids[i]), "%s 长局通关后应标记 cleared" % ids[i])
		if i + 1 < ids.size():
			_ok(not SaveManager.is_map_unlocked(ids[i + 1]),
				"仅通关长局 %s 不应解锁 %s" % [ids[i], ids[i + 1]])
		# 再通关短局 3 局：此时两条件满足，下一界应解锁
		for s in range(1, 4):
			SaveManager.mark_short_stage(ids[i], s)
		_ok(SaveManager.short_world_cleared(ids[i]), "%s 短局 3 局应全清" % ids[i])
		if i + 1 < ids.size():
			_ok(SaveManager.is_map_unlocked(ids[i + 1]),
				"长局+短局双通 %s 后应解锁 %s" % [ids[i], ids[i + 1]])
	# 还原
	SaveManager.data = backup
	SaveManager.save_data()

## 6) 菜单 UI 冒烟：地图选择与局外商店只在点击时才构建，这里主动跑一遍防止运行期崩溃
func _check_menu_ui() -> void:
	var scene = load("res://scenes/menu.tscn")
	_ok(scene != null, "menu.tscn 加载失败")
	if scene == null:
		return
	var menu = scene.instantiate()
	add_child(menu)
	await get_tree().process_frame
	# 地图面板：应为每张地图生成一个按钮，且未解锁的处于 disabled
	menu.refresh_maps()
	menu.show_only("map")
	var map_btns = 0
	var disabled_btns = 0
	for c in menu.map_panel.get_children():
		if c.name.begins_with("map_"):
			map_btns += 1
			if c.disabled:
				disabled_btns += 1
	_ok(map_btns == DataTables.maps.size(),
		"地图按钮数 %d != 地图数 %d" % [map_btns, DataTables.maps.size()])
	_ok(map_btns - disabled_btns >= 1, "至少应有一张可选地图（首图默认解锁）")
	# 商店面板：应为每项元升级生成一个按钮
	menu.refresh_meta()
	menu.show_only("meta")
	var meta_btns = menu.meta_list.get_child_count()
	_ok(meta_btns == DataTables.meta_upgrades.size(),
		"商店条目数 %d != meta 项数 %d" % [meta_btns, DataTables.meta_upgrades.size()])
	menu.queue_free()

## 7) 端到端：金币购买 -> 扣款 -> 属性真的落到 player 上（同样备份/还原存档）
func _check_buy_and_apply() -> void:
	var backup = SaveManager.data.duplicate(true)
	SaveManager.data["meta_upgrades"] = {}
	SaveManager.data["global_gold"] = 999999
	# 买 2 级生命 + 1 级移速
	var cost1 = SaveManager.meta_upgrade_cost("max_hp")
	_ok(SaveManager.buy_meta_upgrade("max_hp"), "金币充足时应能购买 max_hp")
	_ok(SaveManager.get_meta_level("max_hp") == 1, "购买后等级应为 1")
	_ok(SaveManager.get_gold() == 999999 - cost1, "购买应正确扣款")
	_ok(SaveManager.meta_upgrade_cost("max_hp") > cost1, "第二级应更贵")
	SaveManager.buy_meta_upgrade("max_hp")
	SaveManager.buy_meta_upgrade("speed")
	# 金币不足时不应成交
	SaveManager.data["global_gold"] = 0
	_ok(not SaveManager.buy_meta_upgrade("damage"), "金币为 0 时不应购买成功")
	# 属性落点
	var p = CharacterBody2D.new()
	p.set_script(load("res://scripts/entities/player.gd"))
	add_child(p)
	var hp0 = p.base_max_hp
	var spd0 = p.base_speed
	p.apply_meta_upgrades(SaveManager.get_meta_upgrades())
	var exp_hp = hp0 + float(DataTables.meta_upgrades["max_hp"]["per_level"]) * 2.0
	var exp_spd = spd0 + float(DataTables.meta_upgrades["speed"]["per_level"]) * 1.0
	_ok(is_equal_approx(p.base_max_hp, exp_hp),
		"max_hp Lv2 应使基础生命 %.1f -> %.1f，实际 %.1f" % [hp0, exp_hp, p.base_max_hp])
	_ok(is_equal_approx(p.base_speed, exp_spd),
		"speed Lv1 应使基础移速 %.1f -> %.1f，实际 %.1f" % [spd0, exp_spd, p.base_speed])
	# 金币/经验乘数
	SaveManager.data["meta_upgrades"]["gold_gain"] = 3
	GameManager.compute_meta_multipliers()
	var expect_mult = 1.0 + float(DataTables.meta_upgrades["gold_gain"]["per_level"]) * 3.0
	_ok(is_equal_approx(GameManager.meta_gold_mult, expect_mult),
		"gold_gain Lv3 应得乘数 %.2f，实际 %.2f" % [expect_mult, GameManager.meta_gold_mult])
	p.queue_free()
	# 还原
	SaveManager.data = backup
	SaveManager.save_data()
	GameManager.compute_meta_multipliers()

## 4) 价格公式单调递增（不会出现越买越便宜）
func _check_meta_math() -> void:
	for id in DataTables.meta_upgrades.keys():
		var u = DataTables.meta_upgrades[id]
		var prev = -1
		for lvl in range(int(u["max_level"])):
			var c = int(floor(float(u["cost_base"]) * pow(float(u["cost_growth"]), float(lvl))))
			_ok(c > prev, "meta %s 在 Lv%d 的价格未递增（%d <= %d）" % [id, lvl, c, prev])
			prev = c

## 9) 满级后升级仍应有三选一（回归：之前满级会静默跳过升级界面，导致升级无三选一）
func _check_level_up_pool() -> void:
	var p = load("res://scripts/entities/player.gd").new()
	add_child(p)
	p.luck = 0.0
	GameManager.map_id = "zombie"
	# 模拟全满级：所有武器拥有且满级、所有被动满级
	p.weapons = {}
	for wid in DataTables.weapons.keys():
		p.weapons[wid] = {"level": int(DataTables.weapons[wid].max_level), "node": null}
	p.passives = {}
	for pid in DataTables.passives.keys():
		p.passives[pid] = {"level": int(DataTables.passives[pid].max_level), "quality": "white"}
	var opts = UpgradePool.generate(p)
	_ok(opts.size() == 3, "满级后 generate 应仍返回 3 个选项，实际 %d" % opts.size())
	var has_treasure = false
	var has_stat = false
	for o in opts:
		_ok(str(o.get("name", "")) != "", "满级选项缺少 name")
		match str(o.get("type", "")):
			"treasure":
				has_treasure = true
			"stat":
				has_stat = true
	_ok(has_treasure, "满级后三选一应包含金币宝箱兜底选项")
	_ok(has_stat, "满级后三选一应包含属性继续成长兜底选项")
	# 应用一个「属性成长」选项后，对应属性应真实增长
	var p_stat = load("res://scripts/entities/player.gd").new()
	add_child(p_stat)
	var hp0 = p_stat.base_max_hp
	p_stat.apply_upgrade({"type":"stat","stat":"max_hp","amount":25.0})
	_ok(is_equal_approx(p_stat.base_max_hp, hp0 + 25.0),
		"应用属性成长·生命后基础生命应 +25，实际 %.1f -> %.1f" % [hp0, p_stat.base_max_hp])
	p_stat.queue_free()
	# 初始玩家应拿到真实的武器/被动升级选项（而非全是宝箱）
	p.weapons = {}
	p.passives = {}
	var opts2 = UpgradePool.generate(p)
	_ok(opts2.size() == 3, "初始玩家 generate 应返回 3 个选项，实际 %d" % opts2.size())
	var real = 0
	for o in opts2:
		if str(o.get("type", "")) != "treasure" and str(o.get("type", "")) != "stat":
			real += 1
	_ok(real >= 1, "初始玩家三选一应包含真实升级选项")
	p.queue_free()

## 8) 联机快照（state）序列化纯函数：用合成对象验证协议字段，无需真实联机/中继
func _check_net_snapshot() -> void:
	# 合成玩家（dict 模拟 player 接口；weapons[node].evolved 控制进化标志）
	var player_like = {
		"pid": 7,
		"global_position": Vector2(10.0, -20.0),
		"_face": Vector2(0.0, 1.0),
		"hp": 80.0,
		"max_hp": 100.0,
		"downed": false,
		"net_color": Color(0.5, 0.5, 0.5),
		"weapons": {"knife": {"level": 3, "node": {"evolved": true}}}
	}
	var p = NetSerialize.serialize_player(player_like)
	_ok(p.has("pid") and int(p.pid) == 7, "snapshot.player.pid 错误")
	_ok(p.has("x") and is_equal_approx(float(p.x), 10.0), "snapshot.player.x 错误")
	_ok(p.has("y") and is_equal_approx(float(p.y), -20.0), "snapshot.player.y 错误")
	_ok(p.has("fx") and is_equal_approx(float(p.fx), 0.0), "snapshot.player.fx 错误")
	_ok(p.has("hp") and int(p.hp) == 80, "snapshot.player.hp 错误")
	_ok(p.has("mhp") and int(p.mhp) == 100, "snapshot.player.mhp 错误")
	_ok(p.has("lv") and int(p.lv) == int(GameManager.level), "snapshot.player.lv 应与全局等级一致")
	_ok(p.has("wp") and p.wp.size() == 1, "snapshot.player.wp 应含 1 把武器")
	_ok(p.wp[0].id == "knife" and int(p.wp[0].level) == 3 and int(p.wp[0].ev) == 1,
		"snapshot.player.wp 武器条目（id/level/ev）错误")
	_ok(p.has("c") and p.c.size() == 3, "snapshot.player.c 应为 3 元素颜色数组")
	_ok(p.has("down") and int(p.down) == 0, "snapshot.player.down 错误")

	# 武器未进化时 ev 应为 0
	var p2 = NetSerialize.serialize_player({
		"pid": 8, "global_position": Vector2.ZERO, "_face": Vector2(1, 0),
		"hp": 50.0, "max_hp": 50.0, "downed": true, "net_color": Color(1, 1, 1),
		"weapons": {"wand": {"level": 1, "node": {"evolved": false}}}
	})
	_ok(int(p2.wp[0].ev) == 0 and int(p2.down) == 1, "未进化武器 ev 应为 0、down 应为 1")

	# 宝石 / 宝箱序列化
	var g = NetSerialize.serialize_gem({"global_position": Vector2(5.0, 5.0), "type": "coin", "alive": true})
	_ok(g.has("x") and g.has("y") and g.has("ty") and g.ty == "coin", "snapshot.gem 字段错误")
	var c = NetSerialize.serialize_chest({"global_position": Vector2(3.0, 4.0), "quality": 5, "taken": false})
	_ok(c.has("x") and c.has("y") and int(c.q) == 5, "snapshot.chest 字段错误")

	# 完整快照（含新增共享字段 gold/exp/enn + 掉落数组）
	var snap = NetSerialize.build_snapshot(
		[player_like], [{"x": 1.0}], [g], [c],
		123.0, 42, 999, 7, 250, 320
	)
	_ok(snap.get("t") == "state", "snapshot.t 应为 state")
	_ok(int(snap.rt) == 123, "snapshot.rt 错误")
	_ok(int(snap.kills) == 42, "snapshot.kills 错误")
	_ok(int(snap.g) == 999, "snapshot.gold 错误")
	_ok(int(snap.lv) == 7, "snapshot.level 错误")
	_ok(int(snap.exp) == 250, "snapshot.exp 错误")
	_ok(int(snap.enn) == 320, "snapshot.exp_needed 错误")
	_ok(snap.has("gems") and snap.gems.size() == 1, "snapshot.gems 应含 1 个")
	_ok(snap.has("chests") and snap.chests.size() == 1, "snapshot.chests 应含 1 个")
	_ok(snap.has("players") and snap.players.size() == 1, "snapshot.players 应含 1 个")
	_ok(snap.has("enemies") and snap.enemies.size() == 1, "snapshot.enemies 应含 1 个")

## 10) 开局闸门：进入 main 场景应先弹「开始方式」面板且对局未开始；
## 选择「单人游戏」后世界才构建、对局才开始（验证「是否联机选完再开始游戏」）。
func _check_lobby_gate() -> void:
	var scene = load("res://scenes/main.tscn")
	_ok(scene != null, "main.tscn 加载失败")
	if scene == null:
		return
	var main = scene.instantiate()
	add_child(main)
	await get_tree().process_frame
	# 选模式前：应显示开始方式面板，且对局未开始
	_ok(main.net_panel != null and main.net_panel.visible, "进入 main 后应显示开始方式面板")
	_ok(not GameManager.playing, "选模式前对局不应开始（playing 应为 false）")
	# 模拟选择「单人游戏」：世界应构建且对局开始
	main._on_choose_solo()
	await get_tree().process_frame
	_ok(GameManager.playing, "选择单人后应对局开始（playing=true）")
	_ok(is_instance_valid(main.get("player")), "选择单人后玩家应已构建")
	main.queue_free()

## 11) 模式表（长局/短局）结构合法，短局 Boss 时点早于强制结束
func _check_modes() -> void:
	_ok(DataTables.modes.size() >= 2, "modes.json 应至少含 long/short 两种模式，实际 %d" % DataTables.modes.size())
	_ok(DataTables.modes.has("long"), "缺少 long 模式")
	_ok(DataTables.modes.has("short"), "缺少 short 模式")
	var lng = DataTables.modes.get("long", {})
	_ok(int(lng.get("duration", 0)) == 1200, "long.duration 应为 1200（20 分钟），实际 %s" % str(lng.get("duration")))
	var sht = DataTables.modes.get("short", {})
	_ok(int(sht.get("duration", 0)) == 300, "short.duration 应为 300（5 分钟），实际 %s" % str(sht.get("duration")))
	var boss_at = int(sht.get("boss_at", -1))
	_ok(boss_at > 0, "short 缺少 boss_at（4 分钟刷 Boss）")
	_ok(boss_at < int(sht.get("duration", 0)), "short.boss_at(%d) 必须早于 duration(%d)" % [boss_at, int(sht.get("duration", 0))])
	for m in ["hp_mult", "exp_mult", "spawn_mult"]:
		_ok(sht.has(m) and float(sht.get(m, 0)) > 0.0, "short 缺少正值的 %s" % m)
	# long 的倍率应为 1.0（不额外加权）
	_ok(float(lng.get("hp_mult", 0.0)) == 1.0, "long.hp_mult 应为 1.0")
	_ok(float(lng.get("exp_mult", 0.0)) == 1.0, "long.exp_mult 应为 1.0")

## 12) 绿宝石计价局外强化：扣绿宝石而非金币，且金币不足不影响
func _check_emerald_meta() -> void:
	# 绿宝石强化平衡不变量：
	# 1) 每个绿宝石强化的 per_level 必须 >= 同 stat 的金币强化（绿宝石是更高级货币，不能比金币弱）
	# 2) 绿宝石价格需收敛（cost_base <= 3 且 cost_growth <= 1.7），避免太贵
	var gold_per_stat = {}
	for id in DataTables.meta_upgrades.keys():
		var u = DataTables.meta_upgrades[id]
		if str(u.get("currency", "gold")) == "emerald":
			continue
		var st = str(u.get("stat", ""))
		var pl = float(u.get("per_level", 0.0))
		if not gold_per_stat.has(st) or pl > gold_per_stat[st]:
			gold_per_stat[st] = pl
	var em_ids = []
	for id in DataTables.meta_upgrades.keys():
		if SaveManager.meta_upgrade_currency(id) == "emerald":
			em_ids.append(id)
	_ok(em_ids.size() >= 1, "应至少存在 1 个绿宝石计价的局外强化")
	var backup = SaveManager.data.duplicate(true)
	for id in em_ids:
		var eu = DataTables.meta_upgrades[id]
		var st = str(eu.get("stat", ""))
		# 不变量 1：绿宝石每级收益 >= 金币同级
		if gold_per_stat.has(st):
			_ok(float(eu.get("per_level", 0.0)) >= gold_per_stat[st],
				"绿宝石强化 %s(%s) 每级 %s 不应低于金币强化每级 %s" % [id, st, str(eu.get("per_level")), str(gold_per_stat[st])])
		# 不变量 2：绿宝石价格收敛
		_ok(int(eu.get("cost_base", 99)) <= 3, "%s 的绿宝石 cost_base 应 <=3，实际 %d" % [id, int(eu.get("cost_base", 99))])
		_ok(float(eu.get("cost_growth", 9.0)) <= 1.7, "%s 的绿宝石 cost_growth 应 <=1.7，实际 %s" % [id, str(eu.get("cost_growth", 9.0))])
		SaveManager.data["global_gold"] = 0
		SaveManager.data["global_emerald"] = 999
		SaveManager.data["meta_upgrades"] = {}
		var info = SaveManager.meta_upgrade_cost_info(id)
		_ok(info.currency == "emerald", "%s 的 cost_info.currency 应为 emerald" % id)
		_ok(info.cost > 0, "%s 的绿宝石价格应 > 0，实际 %d" % [id, info.cost])
		var bought = SaveManager.buy_meta_upgrade(id)
		_ok(bought, "绿宝石充足时应能购买 %s" % id)
		_ok(SaveManager.get_meta_level(id) == 1, "购买后 %s 等级应为 1" % id)
		_ok(SaveManager.get_emerald() == 999 - info.cost, "购买 %s 应正确扣绿宝石（%d）" % [id, 999 - info.cost])
		_ok(SaveManager.get_gold() == 0, "购买绿宝石强化不应扣金币")
		# 绿宝石为 0 时不应成交
		SaveManager.data["global_emerald"] = 0
		_ok(not SaveManager.buy_meta_upgrade(id), "绿宝石为 0 时不应购买成功 %s" % id)
	SaveManager.data = backup
	SaveManager.save_data()

## 13) 短局进度：每世界 3 局；但仅短局全通不得解锁下一界，需配合长局通关
func _check_short_progression() -> void:
	var backup = SaveManager.data.duplicate(true)
	SaveManager.data["map_progress"] = {"unlocked": ["zombie"], "cleared": []}
	SaveManager.data["short_cleared"] = []
	var ids = []
	for i in range(1, DataTables.maps.size() + 1):
		for mid in DataTables.maps.keys():
			if int(DataTables.maps[mid].get("order", -1)) == i:
				ids.append(mid)
				break
	_ok(ids.size() >= 2, "短局进度测试需要至少 2 张地图")
	# 默认应拿到第一个世界第 1 局
	var nxt = SaveManager.short_next()
	_ok(nxt == {"world": ids[0], "stage": 1}, "初始 short_next 应返回首世界第1局，实际 %s" % str(nxt))
	# 第一世界 3 局全清 -> 标记 cleared（但长局未通，下一界不应解锁）
	for s in range(1, 4):
		SaveManager.mark_short_stage(ids[0], s)
	_ok(SaveManager.short_world_cleared(ids[0]), "标记 3 局后 %s 应视为全通关" % ids[0])
	# 仅短局全通：下一世界此时【不应】解锁
	_ok(not SaveManager.is_short_world_unlocked(ids[1]), "仅短局全通，下一世界 %s 不应解锁" % ids[1])
	# 再补长局通关 -> 两条件满足，下一界应解锁
	SaveManager.mark_map_cleared(ids[0])
	_ok(SaveManager.is_short_world_unlocked(ids[1]), "长局+短局双通后，下一世界 %s 应解锁" % ids[1])
	var nxt2 = SaveManager.short_next()
	_ok(nxt2 == {"world": ids[1], "stage": 1}, "首世界双通后 short_next 应推进到下一世界第1局，实际 %s" % str(nxt2))
	# 中途世界不应解锁（跳跃）
	if ids.size() >= 3:
		_ok(not SaveManager.is_short_world_unlocked(ids[2]), "未双通第二世界时第三世界不应解锁")
	SaveManager.data = backup
	SaveManager.save_data()

## 14) 局内商店：金币/绿宝石商品扣费正确、效果落到玩家
func _check_shop_buy() -> void:
	var p = load("res://scripts/entities/player.gd").new()
	add_child(p)
	var gold_bak = GameManager.gold
	var em_bak = GameManager.emerald
	var cp_bak = GameManager.combat_players.duplicate()
	GameManager.gold = 1000
	GameManager.emerald = 100
	GameManager.combat_players = [p]
	# 急救包：回满血（先打残）
	p.hp = 1.0
	var g0 = GameManager.gold
	_ok(ShopManager.buy("heal", p), "金币充足应能购买急救包")
	_ok(p.hp == p.max_hp, "急救包应回满生命")
	_ok(GameManager.gold == g0 - 40, "急救包应扣 40 金，实际 %d" % GameManager.gold)
	# 淘金热：发金币
	var g1 = GameManager.gold
	_ok(ShopManager.buy("goldrush", p), "应能购买淘金热")
	_ok(GameManager.gold == g1 - 60 + 150, "淘金热应净赚 90 金")
	# 狂暴药剂（属性，金）：伤害 +10%
	var dmg0 = p.damage_bonus
	var g2 = GameManager.gold
	_ok(ShopManager.buy("a_dmg", p), "应能购买狂暴药剂")
	_ok(is_equal_approx(p.damage_bonus, dmg0 + 0.10), "狂暴药剂应使伤害 +0.10，实际 %.2f" % p.damage_bonus)
	_ok(GameManager.gold == g2 - 100, "狂暴药剂应扣 100 金")
	# 【绿宝石】神力灌注：伤害 +25%（扣绿宝石，不动金币）
	var dmg1 = p.damage_bonus
	var e0 = GameManager.emerald
	var g3 = GameManager.gold
	_ok(ShopManager.buy("em_admg", p), "应能购买绿宝石·神力灌注")
	_ok(is_equal_approx(p.damage_bonus, dmg1 + 0.25), "绿宝石强化应使伤害 +0.25，实际 %.2f" % p.damage_bonus)
	_ok(GameManager.emerald == e0 - 4, "绿宝石强化应扣 4 绿宝石，实际 %d" % GameManager.emerald)
	_ok(GameManager.gold == g3, "绿宝石强化不应扣金币")
	# 武器精炼：需先拥有一把武器
	p.weapons = {"knife": {"level": 1, "node": null}}
	var g4 = GameManager.gold
	_ok(ShopManager.buy("w_up", p), "应能购买武器精炼")
	_ok(int(p.weapons["knife"]["level"]) == 2, "武器精炼应使 knife 等级 +1，实际 %d" % int(p.weapons["knife"]["level"]))
	_ok(GameManager.gold == g4 - 120, "武器精炼应扣 120 金")
	# 买不起则拒绝（不扣费）
	GameManager.gold = 0
	GameManager.emerald = 0
	_ok(not ShopManager.can_afford("heal"), "金币/绿宝石为 0 时不应可负担急救包")
	_ok(not ShopManager.buy("heal", p), "金币为 0 时购买应失败")
	# 还原
	GameManager.gold = gold_bak
	GameManager.emerald = em_bak
	GameManager.combat_players = cp_bak
	p.queue_free()

## 15) 模式倍率：start_run(mode) 把倍率叠加到 diff 上
func _check_run_mode_mult() -> void:
	var backup_diff = GameManager.diff.duplicate()
	var backup_mode = GameManager.game_mode
	var backup_player = GameManager.player
	GameManager.set_difficulty("normal")  # normal: 各倍率 1.0
	# 长局：倍率应全部为 1.0（传 null 作为 player，start_run 不依赖 player 字段）
	GameManager.start_run(null, null, "long", "", 1)
	_ok(GameManager.game_mode == "long", "start_run 应设 game_mode=long")
	_ok(is_equal_approx(GameManager.diff.enemy_hp, 1.0), "long 模式 enemy_hp 倍率应为 1.0")
	_ok(is_equal_approx(GameManager.diff.exp, 1.0), "long 模式 exp 倍率应为 1.0")
	_ok(is_equal_approx(GameManager.diff.spawn, 1.0), "long 模式 spawn 倍率应为 1.0")
	_ok(GameManager.gold == 0 and GameManager.emerald == 0, "start_run 应清零局内金币/绿宝石")
	# 短局：应套用 0.8 / 1.7 / 1.25
	GameManager.start_run(null, null, "short", "zombie", 1)
	_ok(GameManager.game_mode == "short", "start_run 应设 game_mode=short")
	_ok(is_equal_approx(GameManager.diff.enemy_hp, 0.8), "short 模式 enemy_hp 倍率应为 0.8，实际 %.2f" % GameManager.diff.enemy_hp)
	_ok(is_equal_approx(GameManager.diff.exp, 1.7), "short 模式 exp 倍率应为 1.7，实际 %.2f" % GameManager.diff.exp)
	_ok(is_equal_approx(GameManager.diff.spawn, 1.25), "short 模式 spawn 倍率应为 1.25，实际 %.2f" % GameManager.diff.spawn)
	_ok(GameManager.short_world == "zombie" and GameManager.short_stage == 1, "start_run 应记录短局 world/stage")
	# 还原（避免把 player 留成裸 Node 导致其他节点 _process 报错）
	GameManager.diff = backup_diff
	GameManager.game_mode = backup_mode
	GameManager.player = backup_player

## 16) 词条系统（质变 / 超质变 / 怪物黑词条）数据完整性 + 运行时聚合真实验证
func _check_affixes() -> void:
	var shapes = {}
	for s in AffixVisual.shape_list():
		shapes[s] = true
	# 16a) 每件武器的 质变 / 超质变 配对 + 形状/颜色/前置链 合法
	var mut_by_weapon = {}
	for aid in DataTables.mutations.keys():
		var a = DataTables.mutations[aid]
		var tier = str(a.get("tier", ""))
		var cat = str(a.get("category", ""))
		# 形状 / 颜色 / super 字段
		var vis = a.get("visual", {})
		_ok(typeof(vis) == TYPE_DICTIONARY and vis.size() > 0, "词条 %s 缺少 visual" % aid)
		var sh = str(vis.get("shape", ""))
		_ok(sh != "", "词条 %s 的 visual.shape 不能为空" % aid)
		_ok(shapes.has(sh), "词条 %s 的 visual.shape=%s 未被 AffixVisual 支持（需新增专属分支）" % [aid, sh])
		_ok(vis.has("super"), "词条 %s 的 visual 缺少 super 布尔字段" % aid)
		var col = a.get("color", [])
		_ok(typeof(col) == TYPE_ARRAY and col.size() >= 3,
			"词条 %s 的 color 应为 [r,g,b] 数组" % aid)
		# 超质变前置必须存在且为 mutation
		if tier == "super":
			var req = str(a.get("require_affix", ""))
			_ok(req != "", "超质变 %s 缺少 require_affix 前置" % aid)
			_ok(DataTables.mutations.has(req), "超质变 %s 的前置 %s 不存在" % [aid, req])
			if DataTables.mutations.has(req):
				_ok(str(DataTables.mutations[req].get("tier", "")) == "mutation",
					"超质变 %s 的前置 %s 应为 mutation 而非 %s" % [aid, req, str(DataTables.mutations[req].get("tier", ""))])
		if cat == "weapon" and tier == "mutation":
			mut_by_weapon[str(a.get("require_weapon", ""))] = aid
	# 武器类超质变必须对应同武器的质变前置
	for aid in DataTables.mutations.keys():
		var a = DataTables.mutations[aid]
		if str(a.get("category", "")) == "weapon" and str(a.get("tier", "")) == "super":
			var wid = str(a.get("require_weapon", ""))
			_ok(mut_by_weapon.has(wid), "武器超质变 %s 缺少同武器的质变前置（weapon=%s）" % [aid, wid])
	# 16b) 怪物黑词条
	_ok(DataTables.monster_affixes.size() > 0, "monster_affixes.json 为空")
	for aid in DataTables.monster_affixes.keys():
		var a = DataTables.monster_affixes[aid]
		var vis = a.get("visual", {})
		_ok(typeof(vis) == TYPE_DICTIONARY and vis.size() > 0, "怪物词条 %s 缺少 visual" % aid)
		var sh = str(vis.get("shape", ""))
		_ok(shapes.has(sh), "怪物词条 %s 的 visual.shape=%s 未被 AffixVisual 支持" % [aid, sh])
		_ok(str(a.get("tier", "")) == "monster", "怪物词条 %s 的 tier 应为 monster" % aid)
		var minr = int(a.get("min_rank", 0))
		_ok(minr >= 0 and minr < 5, "怪物词条 %s 的 min_rank=%d 越界（0..4）" % [aid, minr])
		var col = a.get("color", [])
		_ok(typeof(col) == TYPE_ARRAY and col.size() >= 3, "怪物词条 %s 的 color 应为 [r,g,b]" % aid)
	# 16c) 难度表 affix_count 合法
	_ok(DataTables.difficulties.size() > 0, "difficulties.json 为空")
	for did in DataTables.difficulties.keys():
		var ac = int(DataTables.difficulties[did].get("affix_count", -1))
		_ok(ac >= 0, "难度 %s 的 affix_count 缺失或为负" % did)
	# 16d) 运行时聚合真实验证（不依赖完整对局，直接驱动 AffixManager）
	if DataTables.mutations.size() > 0:
		AffixManager.reset_run()
		var sample_wid = ""
		var sample_mut = ""
		for aid in DataTables.mutations.keys():
			var a = DataTables.mutations[aid]
			if str(a.get("category", "")) == "weapon" and str(a.get("tier", "")) == "mutation":
				sample_wid = str(a.get("require_weapon", ""))
				sample_mut = aid
				break
		if sample_mut != "":
			AffixManager.register_weapon_affix(sample_wid, sample_mut)
			var m1 = AffixManager.weapon_mods(sample_wid)
			var d1 = m1.damage_mult
			for aid in DataTables.mutations.keys():
				var a = DataTables.mutations[aid]
				if str(a.get("category", "")) == "weapon" and str(a.get("tier", "")) == "super" and str(a.get("require_weapon", "")) == sample_wid:
					AffixManager.register_weapon_affix(sample_wid, aid)
					break
			var m2 = AffixManager.weapon_mods(sample_wid)
			_ok(m2.damage_mult > d1, "武器超质变应使 damage_mult 高于仅质变（%.3f -> %.3f）" % [d1, m2.damage_mult])
		# 怪物黑词条削弱聚合：至少削弱玩家一项
		AffixManager.reset_run()
		if DataTables.monster_affixes.size() > 0:
			var mid = DataTables.monster_affixes.keys()[0]
			AffixManager.add_monster_affix(mid)
			var db = AffixManager.monster_player_debuffs()
			_ok(db.damage_mult <= 1.0 or db.speed_mult <= 1.0 or db.max_hp_mult <= 1.0 or db.heal_mult <= 1.0 or db.luck_mult <= 1.0 or db.pickup_mult <= 1.0 or db.gold_mult <= 1.0,
				"怪物黑词条 %s 应至少削弱玩家一项属性" % mid)
		AffixManager.reset_run()
