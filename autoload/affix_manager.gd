extends Node
## AffixManager —— 质变 / 超质变 / 怪物黑色词条 的统一中枢（2026-08-16 新增）
##
## 三类词条：
##   * mutation  / super  —— 亮蓝色 / 彩色，仅在有对应武器时（且超质变需先拥有对应质变）才能获取；
##                          概率 0.5% × 幸运加成，只出现在三选一与商店刷新中。
##   * monster（黑）      —— 每局开局以三选一出现（免费3次后金币刷新），按难度决定数量，
##                          同时加强怪物并对玩家削弱。
##
## 设计原则：数据驱动（data/mutations.json、data/monster_affixes.json），代码只做聚合与施加。
## 所有"当前生效"的词条都通过本 autoload 聚合，玩家/武器/敌人按需查询，避免散落各处的字段污染。

# 难度顺序与每局黑色词条数量（简单=0，往后递增）
const DIFF_ORDER = ["simple", "normal", "hard", "purgatory", "extreme"]
const AFFIX_COUNT_BY_DIFF = {"simple": 0, "normal": 1, "hard": 2, "purgatory": 3, "extreme": 4}

var mutations = {}        # id -> affix（质/超，武器+玩家）
var monster_affixes = {}  # id -> affix（黑）

# 当前对局生效的词条
var active_weapon: Dictionary = {}   # wid -> [affix_id, ...]
var active_player: Array = []        # [affix_id, ...]
var active_monster: Array = []       # [affix_id, ...]

# 武器命中特效节流：uid -> 上次触发时间（避免光环/环绕每帧狂炸）
var _fx_cd: Dictionary = {}

# ---- 商店刷新（质变/超质变也会作为商品出现在局内商店）----
var shop_refresh_count: int = 0
var shop_refresh_base: int = 25
var shop_refresh_growth: float = 1.6
var affix_stock: Dictionary = {}     # item_id -> {affix_id, currency, cost, ...}

func _ready() -> void:
	_load_data()

func _load_data() -> void:
	mutations = DataTables.mutations
	monster_affixes = DataTables.monster_affixes

## 开局重置（每次 start_run 调用，清空上一局的全部词条）
func reset_run() -> void:
	active_weapon = {}
	active_player = []
	active_monster = []
	_fx_cd = {}
	shop_refresh_count = 0
	affix_stock = {}

## ---------- 注册 ----------
func register_weapon_affix(wid: String, aid: String) -> void:
	if not mutations.has(aid):
		return
	if not active_weapon.has(wid):
		active_weapon[wid] = []
	if not active_weapon[wid].has(aid):
		active_weapon[wid].append(aid)

func register_player_affix(aid: String) -> void:
	if not mutations.has(aid):
		return
	if not active_player.has(aid):
		active_player.append(aid)

func add_monster_affix(aid: String) -> void:
	if not monster_affixes.has(aid):
		return
	if not active_monster.has(aid):
		active_monster.append(aid)

func owns_affix(aid: String) -> bool:
	if active_player.has(aid):
		return true
	for wid in active_weapon.keys():
		if active_weapon[wid].has(aid):
			return true
	return false

## 该武器是否已拥有其质变（超质变的前置门槛）
func has_mutation(wid: String) -> bool:
	if not active_weapon.has(wid):
		return false
	for aid in active_weapon[wid]:
		var a = mutations.get(aid, {})
		if str(a.get("tier", "")) == "mutation":
			return true
	return false

## ---------- 概率 ----------
## 单槽位出现质变/超质变的基础概率（用户要求 0.5%），并吃幸运加成
func pick_chance(luck: float) -> float:
	return 0.005 * (1.0 + max(0.0, luck) * 0.06)

## ---------- 升级三选一 / 商店：可选项收集 ----------
## 仅返回「当前可获取」的词条选项（已拥有的不再出现）
func collect_mutation_options(player) -> Array:
	var out = []
	# 武器质变：玩家已拥有该武器，且尚未拥有其质变
	for wid in player.weapons.keys():
		var mut_id = _mutation_id_for_weapon(wid)
		if mut_id != "" and not owns_affix(mut_id):
			out.append(_option_from_affix(mut_id, player))
	# 玩家质变（通用，不限武器）
	for aid in mutations.keys():
		var a = mutations[aid]
		if str(a.get("category", "")) != "player":
			continue
		if str(a.get("tier", "")) != "mutation":
			continue
		if owns_affix(aid):
			continue
		out.append(_option_from_affix(aid, player))
	return out

## 超质变：必须已拥有对应前置质变，且自身尚未拥有
func collect_super_options(player) -> Array:
	var out = []
	for aid in mutations.keys():
		var a = mutations[aid]
		if str(a.get("tier", "")) != "super":
			continue
		var req = str(a.get("require_affix", ""))
		if req != "" and not owns_affix(req):
			continue
		if owns_affix(aid):
			continue
		out.append(_option_from_affix(aid, player))
	return out

func _mutation_id_for_weapon(wid: String) -> String:
	for aid in mutations.keys():
		var a = mutations[aid]
		if str(a.get("category", "")) == "weapon" and str(a.get("tier", "")) == "mutation" and str(a.get("require_weapon", "")) == wid:
			return aid
	return ""

func _option_from_affix(aid: String, player) -> Dictionary:
	var a = mutations[aid]
	var col = Color(0.5, 0.8, 1.0)
	var carr = a.get("color", [0.5, 0.8, 1.0])
	if typeof(carr) == TYPE_ARRAY and carr.size() >= 3:
		col = Color(float(carr[0]), float(carr[1]), float(carr[2]))
	return {
		"type": "affix",
		"tier": a.get("tier", "mutation"),
		"category": a.get("category", "weapon"),
		"require_weapon": a.get("require_weapon", ""),
		"affix_id": aid,
		"name": a.get("name", aid),
		"desc": a.get("desc", ""),
		"weight": 0,
		"quality": null,
		"quality_color": "#%s" % col.to_html(false)
	}

## ---------- 聚合：武器 ----------
func weapon_mods(wid: String) -> Dictionary:
	var m = {
		"damage_mult": 1.0, "cooldown_mult": 1.0, "area_mult": 1.0,
		"knockback_mult": 1.0, "projectile_speed_mult": 1.0,
		"count_add": 0, "pierce_add": 0, "crit_add": 0.0, "shield_pen_add": 0.0,
		"flags": []
	}
	if not active_weapon.has(wid):
		return m
	for aid in active_weapon[wid]:
		var a = mutations.get(aid, {})
		for e in a.get("effects", []):
			var kind = str(e.get("kind", ""))
			if kind == "wstat":
				_apply_wstat(m, e)
			elif kind == "wflag":
				m.flags.append({"flag": str(e.get("flag", "")), "value": float(e.get("value", 1.0))})
	return m

func _apply_wstat(m: Dictionary, e: Dictionary) -> void:
	var stat = str(e.get("stat", ""))
	var v = float(e.get("value", 0.0))
	match stat:
		"damage_mult": m.damage_mult *= (1.0 + v)
		"cooldown_mult": m.cooldown_mult *= v   # v<1 表示更快
		"area_mult": m.area_mult *= (1.0 + v)
		"knockback_mult": m.knockback_mult *= (1.0 + v)
		"projectile_speed_mult": m.projectile_speed_mult *= (1.0 + v)
		"count_add": m.count_add += int(v)
		"pierce_add": m.pierce_add += int(v)
		"crit_add": m.crit_add += v
		"shield_pen_add": m.shield_pen_add += v

## 武器命中时触发特殊特效（explode/chain/burn/freeze/lifesteal_hit/gold_on_hit 等）
func apply_weapon_hit(wid: String, uid: int, dmg: float, source) -> void:
	if not active_weapon.has(wid):
		return
	var now = GameManager.run_time
	for aid in active_weapon[wid]:
		var a = mutations.get(aid, {})
		for e in a.get("effects", []):
			if str(e.get("kind", "")) != "wflag":
				continue
			var flag = str(e.get("flag", ""))
			var strength = float(e.get("value", 1.0))
			if _fx_blocked(uid, flag, now):
				continue
			_fx_trigger(uid, flag, strength, dmg, source)

## 节流：同一敌人对同一特效 0.18s 内只触发一次
func _fx_blocked(uid: int, flag: String, now: float) -> bool:
	var key = str(uid) + "|" + flag
	if _fx_cd.has(key) and now - _fx_cd[key] < 0.18:
		return true
	_fx_cd[key] = now
	return false

func _fx_trigger(uid: int, flag: String, strength: float, dmg: float, source) -> void:
	match flag:
		"explode":
			if EnemyManager.has_method("aoe_burst"):
				EnemyManager.aoe_burst(uid, dmg * 0.6 * strength, 95.0, source)
		"chain":
			if EnemyManager.has_method("chain_to"):
				# 超质变（strength>=1.5）：更多跳数 + 彩虹闪电可视化
				var is_super = strength >= 1.5
				EnemyManager.chain_to(uid, dmg * 0.5 * strength, 4 if is_super else 2, source, is_super)
		"burn":
			EnemyManager.add_status(uid, "burn", 3.0, dmg * 0.12 * strength)
		"freeze":
			EnemyManager.add_status(uid, "freeze", 1.6, strength)
		"lifesteal_hit":
			if source != null and source.has_method("heal"):
				source.heal(dmg * 0.06 * strength)
		"gold_on_hit":
			GameManager.gold += int(1 * strength)
		"shield_break":
			# 额外护盾穿透：在敌人现有护盾上再直接扣一层
			EnemyManager.shield_strike(uid, dmg * 0.5 * strength, source)
	# 其余 flag（pierce_all/split/crit_up/knockback_up 等）是数值类，已在 weapon_mods 中处理，
	# 或由具体武器行为在发射时读取 flags 处理（见 weapon_base）。

## ---------- 聚合：玩家（质变类）----------
func player_affix_mods() -> Dictionary:
	var m = {
		"damage_mult": 1.0, "cooldown_add": 0.0, "speed_mult": 1.0,
		"max_hp_mult": 1.0, "luck_mult": 1.0, "crit_add": 0.0,
		"lifesteal_add": 0.0, "shield_pen_add": 0.0, "pickup_mult": 1.0,
		"heal_mult": 1.0, "gold_mult": 1.0
	}
	for aid in active_player:
		var a = mutations.get(aid, {})
		for e in a.get("effects", []):
			if str(e.get("kind", "")) != "pstat":
				continue
			var stat = str(e.get("stat", ""))
			var v = float(e.get("value", 0.0))
			match stat:
				"damage_mult": m.damage_mult *= (1.0 + v)
				"speed_mult": m.speed_mult *= (1.0 + v)
				"max_hp_mult": m.max_hp_mult *= (1.0 + v)
				"luck_mult": m.luck_mult *= (1.0 + v)
				"pickup_mult": m.pickup_mult *= (1.0 + v)
				"heal_mult": m.heal_mult *= (1.0 + v)
				"gold_mult": m.gold_mult *= (1.0 + v)
				"crit_add": m.crit_add += v
				"lifesteal_add": m.lifesteal_add += v
				"shield_pen_add": m.shield_pen_add += v
	return m

## ---------- 聚合：怪物（黑色词条）----------
func monster_enemy_mods() -> Dictionary:
	var m = {"hp_mult": 1.0, "damage_mult": 1.0, "touch_dmg_mult": 1.0,
		"speed_mult": 1.0, "shield_add": 0.0, "regen": 0.0}
	for aid in active_monster:
		var a = monster_affixes.get(aid, {})
		for e in a.get("effects", []):
			if str(e.get("kind", "")) != "estat":
				continue
			var stat = str(e.get("stat", ""))
			var v = float(e.get("value", 0.0))
			match stat:
				"hp_mult": m.hp_mult *= (1.0 + v)
				"damage_mult": m.damage_mult *= (1.0 + v)
				"touch_dmg_mult": m.touch_dmg_mult *= (1.0 + v)
				"speed_mult": m.speed_mult *= (1.0 + v)
				"shield": m.shield_add += v
				"regen": m.regen += v
	return m

func monster_player_debuffs() -> Dictionary:
	var m = {"damage_mult": 1.0, "speed_mult": 1.0, "max_hp_mult": 1.0,
		"heal_mult": 1.0, "luck_mult": 1.0, "pickup_mult": 1.0, "gold_mult": 1.0}
	for aid in active_monster:
		var a = monster_affixes.get(aid, {})
		for e in a.get("effects", []):
			if str(e.get("kind", "")) != "dstat":
				continue
			var stat = str(e.get("stat", ""))
			var v = float(e.get("value", 0.0))
			match stat:
				"damage_mult": m.damage_mult *= (1.0 + v)
				"speed_mult": m.speed_mult *= (1.0 + v)
				"max_hp_mult": m.max_hp_mult *= (1.0 + v)
				"heal_mult": m.heal_mult *= (1.0 + v)
				"luck_mult": m.luck_mult *= (1.0 + v)
				"pickup_mult": m.pickup_mult *= (1.0 + v)
				"gold_mult": m.gold_mult *= (1.0 + v)
	return m

## 开局选完黑色词条后，把"对玩家的削弱"一次性施加到玩家字段上（仅每局一次）
func apply_monster_debuffs(player) -> void:
	var d = monster_player_debuffs()
	if d.damage_mult != 1.0:
		player.damage_bonus *= d.damage_mult
	if d.speed_mult != 1.0:
		player.base_speed *= d.speed_mult
		player.speed = player.base_speed
	if d.max_hp_mult != 1.0:
		player.base_max_hp *= d.max_hp_mult
		player.max_hp = player.base_max_hp
		player.hp = player.max_hp
	if d.luck_mult != 1.0:
		player.luck *= d.luck_mult
	if d.pickup_mult != 1.0:
		player.pickup_range *= d.pickup_mult
	if d.heal_mult != 1.0:
		player.heal_mult *= d.heal_mult
	if d.gold_mult != 1.0:
		GameManager.meta_gold_mult *= d.gold_mult

## ---------- 商店：质变/超质变商品 + 金币刷新 ----------
func refresh_cost() -> int:
	return int(round(shop_refresh_base * pow(shop_refresh_growth, shop_refresh_count)))

## 重新生成可购买的质变/超质变商品（进商店/点刷新时调用）
func rebuild_affix_stock(player) -> void:
	affix_stock = {}
	var pool = []
	pool.append_array(collect_mutation_options(player))
	pool.append_array(collect_super_options(player))
	if pool.is_empty():
		return
	# 取最多 3 个不重复
	pool.shuffle()
	var n = min(3, pool.size())
	for i in range(n):
		var opt = pool[i]
		var item_id = "affix_" + str(opt.affix_id)
		var tier = str(opt.get("tier", "mutation"))
		var cost = 120 if tier == "mutation" else 320
		affix_stock[item_id] = {
			"id": item_id, "name": opt.name, "desc": opt.desc,
			"category": "affix", "affix_id": opt.affix_id,
			"currency": "gold", "cost": cost, "tier": tier
		}

## 购买一件质变/超质变商品
func buy_affix(item_id: String, player) -> bool:
	if not affix_stock.has(item_id):
		return false
	var it = affix_stock[item_id]
	var cost = int(it.cost)
	if GameManager.gold < cost:
		return false
	var aid = str(it.affix_id)
	var a = mutations.get(aid, {})
	# 已拥有则直接拒绝（避免重复扣金后注册被去重、金币白扣）
	if str(a.get("category", "")) == "player":
		if active_player.has(aid):
			return false
	else:
		var wid = str(a.get("require_weapon", ""))
		if wid == "":
			wid = _first_owned_weapon_of(aid, player)
		if wid != "" and active_weapon.has(wid) and active_weapon[wid].has(aid):
			return false
	GameManager.gold -= cost
	if str(a.get("category", "")) == "player":
		if not active_player.has(aid):
			register_player_affix(aid)
			if player != null and player.has_method("apply_player_affix"):
				player.apply_player_affix(aid)
	else:
		var wid = str(a.get("require_weapon", ""))
		if wid == "":
			wid = _first_owned_weapon_of(aid, player)
		if wid != "":
			register_weapon_affix(wid, aid)
	affix_stock.erase(item_id)
	GameManager.emit_signal("hud_changed")
	return true

func _first_owned_weapon_of(aid: String, player) -> String:
	var a = mutations.get(aid, {})
	return str(a.get("require_weapon", ""))

## 某黑色词条是否可在当前难度出现（按 min_rank 过滤）
func monster_affix_eligible(aid: String, diff_id: String) -> bool:
	var a = monster_affixes.get(aid, {})
	var minr = int(a.get("min_rank", 0))
	var rank = DIFF_ORDER.find(diff_id)
	if rank < 0:
		rank = 1
	return minr <= rank

func monster_affix_count(diff_id: String) -> int:
	if AFFIX_COUNT_BY_DIFF.has(diff_id):
		return int(AFFIX_COUNT_BY_DIFF[diff_id])
	return 0

## 生成本局黑色词条三选一的候选项（按难度过滤 + 不重复）
func roll_monster_choices(diff_id: String, n: int) -> Array:
	var pool = []
	for aid in monster_affixes.keys():
		if monster_affix_eligible(aid, diff_id):
			pool.append(aid)
	pool.shuffle()
	var out = []
	for i in range(min(n, pool.size())):
		out.append(pool[i])
	return out
