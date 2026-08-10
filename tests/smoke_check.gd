extends Node
## smoke_check —— 无头自检（数据一致性 + 局外强化落点）
## 用法：Godot --headless --path rougelike_game res://tests/smoke_check.tscn
## 只读校验，不写存档；任何一项失败以非零退出码结束，便于 CI/脚本捕获。

var fails = []
var checks = 0

func _ready():
	_check_maps()
	_check_weapons_maps()
	_check_weapon_visuals()
	_check_meta_stats()
	_check_meta_math()
	_check_unlock_chain()
	await _check_menu_ui()
	_check_buy_and_apply()
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
	var known = {
		"projectile": ["dart", "bolt", "arrow", "feather", "sword", "thunder", "talisman_shot"],
		"aura": ["vine", "tower", "landscape", "talisman", "default"],
		"orbit": ["page", "crescent", "hammer", "beast", "treasure", "sword_array"],
	}
	for wid in DataTables.weapons.keys():
		var w = DataTables.weapons[wid]
		var t = str(w.get("type", ""))
		var vis = w.get("visual", {})
		_ok(typeof(vis) == TYPE_DICTIONARY and vis.size() > 0,
			"武器 %s 缺少 visual 字段" % wid)
		var shape = str(vis.get("shape", ""))
		_ok(known.has(t) and known[t].has(shape),
			"武器 %s 的 visual.shape=%s 与 type=%s 不匹配" % [wid, shape, t])
		# 颜色存在且为 3 元素数组（缺失会用兜底色，但数据应完整）
		for ck in ["color", "color2"]:
			if vis.has(ck):
				var c = vis[ck]
				_ok(typeof(c) == TYPE_ARRAY and c.size() >= 3,
					"武器 %s visual.%s 应为 [r,g,b] 数组" % [wid, ck])

## 3) meta_upgrades 的 stat 必须是 player 已实现的字段名
func _check_meta_stats() -> void:
	var known = ["max_hp", "damage", "speed", "pickup", "cooldown", "armor",
		"luck", "crit", "crit_dmg", "lifesteal", "revives", "gold_gain", "exp_gain"]
	_ok(DataTables.meta_upgrades.size() > 0, "meta_upgrades.json 为空")
	for id in DataTables.meta_upgrades.keys():
		var u = DataTables.meta_upgrades[id]
		_ok(known.has(str(u.get("stat", ""))), "meta %s 的 stat=%s 未被 player 实现" % [id, u.get("stat", "")])
		_ok(int(u.get("max_level", 0)) > 0, "meta %s 的 max_level 非法" % id)
		_ok(int(u.get("cost_base", 0)) > 0, "meta %s 的 cost_base 非法" % id)
		_ok(float(u.get("cost_growth", 0.0)) >= 1.0, "meta %s 的 cost_growth 应 >= 1.0" % id)

## 5) 通关解锁链：逐张通关应依次解锁下一界，且不越级
## 用深拷贝备份真实存档，验证后原样写回，避免污染玩家进度。
func _check_unlock_chain() -> void:
	var backup = SaveManager.data.duplicate(true)
	SaveManager.data["map_progress"] = {"unlocked": ["zombie"], "cleared": []}
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
		SaveManager.mark_map_cleared(ids[i])
		_ok(SaveManager.is_map_cleared(ids[i]), "%s 通关后应标记 cleared" % ids[i])
		if i + 1 < ids.size():
			_ok(SaveManager.is_map_unlocked(ids[i + 1]),
				"通关 %s 后应解锁 %s" % [ids[i], ids[i + 1]])
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
