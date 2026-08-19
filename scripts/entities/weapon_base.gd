extends Node2D
const WeaponVisual = preload("res://scripts/systems/weapon_visual.gd")
## WeaponBase —— 武器行为基类（GDD §4）
## 数据驱动。三类行为：projectile（投射）/ aura（光环）/ orbit（环绕）。
## 命中全部走 EnemyManager（空间哈希手动查询），不再依赖物理信号。

var data = {}
var level = 1
var player = null
var world = null
var main = null

var cooldown_timer = 0.0
var evolved = false

# orbit 相关
var orbit_children = []
var orbit_root = null
var orbit_angle = 0.0
var orbit_hit_cd = {}

# sweep 相关（横扫：以玩家为中心旋转的刀光线段，命中线段上的敌人，按敌人冷却周期触发）
var sweep_angle = 0.0
var sweep_hit_cd = {}

# 词条聚合缓存：每帧只向 AffixManager 取一次 weapon_mods，避免每次 effective_* 都重算
var _mods_cache: Dictionary = {}
var _mods_frame: int = -1

func _wid() -> String:
	return str(data.get("id", ""))

func _amods() -> Dictionary:
	var f = Engine.get_process_frames()
	if f != _mods_frame:
		_mods_cache = AffixManager.weapon_mods(_wid())
		_mods_frame = f
	return _mods_cache

func _has_flag(flag: String) -> bool:
	for f in _amods().flags:
		if f.flag == flag:
			return true
	return false

func _flag_value(flag: String) -> float:
	var tot = 0.0
	for f in _amods().flags:
		if f.flag == flag:
			tot += float(f.get("value", 1.0))
	return tot

## 武器质变等级（用于特效视觉升级）：""=无 / "mut"=质变 / "super"=超质变
func _mut_tier() -> String:
	var aw = AffixManager.active_weapon.get(_wid(), [])
	var has_super = false
	var has_mut = false
	for aid in aw:
		var a = AffixManager.mutations.get(aid, {})
		var tier = str(a.get("tier", ""))
		if tier == "super":
			has_super = true
		elif tier == "mutation":
			has_mut = true
	if has_super:
		return "super"
	if has_mut:
		return "mut"
	return ""

## 带质变等级的外观数据（复制一份，避免污染 DataTables 数据表）
func _visual_with_tier() -> Dictionary:
	var v = data.get("visual", {}).duplicate()
	v["tier"] = _mut_tier()
	return v

func setup(d: Dictionary, p, w, m) -> void:
	data = d
	player = p
	world = w
	main = m

func on_level_up(lv: int) -> void:
	level = lv
	if data.type == "orbit":
		_rebuild_orbit()

## ---- 数值缩放（GDD §4.3 / §10.2）----
func effective_cooldown() -> float:
	var m = _amods()
	var base = float(data.cooldown)
	base *= (1.0 - player.cooldown_reduction)
	base *= m.cooldown_mult
	return max(0.1, base)

func effective_damage() -> float:
	var m = _amods()
	var d = float(data.damage) * _level_scaling() * (1.0 + player.damage_bonus)
	if evolved:
		d *= 2.5
	d *= m.damage_mult
	return d

func _level_scaling() -> float:
	return 1.0 + 0.15 * float(level - 1)

func effective_count() -> int:
	var m = _amods()
	var c = int(data.count) + int((level - 1) / 3) + int(m.count_add)
	if evolved and data.evolution == "infinite_knife":
		c += 5
	if data.type == "orbit" and _has_flag("orbit_storm"):
		c += 8
	return max(1, c)

func effective_area() -> float:
	return float(data.area) * (1.0 + 0.05 * float(level - 1)) * _amods().area_mult

## 护盾穿透：武器自带 shield_pen（破盾弓等），随等级线性增强，封顶 1.0；
## 叠加词条附加的 shield_pen_add。
func effective_shield_pen() -> float:
	var m = _amods()
	var sp = float(data.get("shield_pen", 0.0)) + m.shield_pen_add
	if sp <= 0.0:
		return 0.0
	return min(1.0, sp + 0.06 * float(level - 1))

func evolve() -> void:
	evolved = true

## ---- 主循环 ----
func _process(delta: float) -> void:
	if not GameManager.playing:
		return
	# 武器节点跟随玩家，使光环/挂载点处于玩家位置
	global_position = player.global_position
	if data.type == "orbit":
		_rotate_orbit(delta)
	elif data.type == "sweep":
		_rotate_sweep(delta)
	cooldown_timer -= delta
	if cooldown_timer <= 0:
		cooldown_timer = effective_cooldown()
		fire()
	queue_redraw()   # 光环/环绕/横扫每帧重绘以驱动特效动画

func fire() -> void:
	match data.type:
		"projectile": _fire_projectile()
		"aura":       _fire_aura()
		"orbit":      pass  # orbit 由 _rotate_orbit 持续命中
		"sweep":      pass  # sweep 由 _rotate_sweep 持续命中
		_:            _fire_projectile()
	# 玩家攻击动画（挥击弧光）：投射/光环开火时触发
	if player != null and player.has_method("notify_attack"):
		player.notify_attack()

func _fire_projectile() -> void:
	var uid = EnemyManager.get_nearest(player.global_position)
	if uid < 0:
		return
	var target_pos = EnemyManager.get_enemy_pos(uid)
	if target_pos == Vector2.ZERO:
		return
	var m = _amods()
	var base_dir = (target_pos - player.global_position).normalized()
	var n = effective_count()
	var spread = deg_to_rad(12)
	var speed = float(data.projectile_speed) * m.projectile_speed_mult
	var kb = float(data.knockback) * m.knockback_mult
	if _has_flag("knockback_up"):
		kb *= _flag_value("knockback_up")
	var pierce = int(data.pierce) + int(m.pierce_add)
	if _has_flag("pierce_all"):
		pierce = 9999
	var crit_bonus = _flag_value("crit_up")
	var split_count = int(round(_flag_value("split")))
	var vd = _visual_with_tier()   # 外观 + 质变等级（驱动质变/超质变特效升级）
	for i in range(n):
		var ang = base_dir.angle() + (i - (n - 1) / 2.0) * spread
		var dir = Vector2(cos(ang), sin(ang))
		var proj = main.get_projectile()
		if proj == null:
			return
		proj.launch(player.global_position + dir * 18.0, dir * speed,
			effective_damage(), pierce, kb, 2.0, main, player, vd, effective_shield_pen(),
			crit_bonus, split_count, _wid())

func _fire_aura() -> void:
	var m = _amods()
	var r = 80.0 * effective_area()
	var dmg = effective_damage()
	var crit_bonus = _flag_value("crit_up")
	var uids = EnemyManager.query_near(global_position, r)
	for uid in uids:
		EnemyManager.take_damage(uid, dmg, Vector2.ZERO, 0.0, player, effective_shield_pen(), crit_bonus)
		AffixManager.apply_weapon_hit(_wid(), uid, dmg, player)
	# 治疗光环（治愈师专属）：在光环范围内的玩家持续回血（按等级缩放）
	var heal_self = float(data.get("heal_self", 0.0))
	if heal_self > 0.0 and player != null and is_instance_valid(player):
		player.heal(player.max_hp * heal_self * _level_scaling())

func _rebuild_orbit() -> void:
	if orbit_root == null:
		orbit_root = Node2D.new()
		orbit_root.name = "OrbitRoot"
		add_child(orbit_root)
	for c in orbit_children:
		c.queue_free()
	orbit_children = []
	var n = effective_count()
	for i in range(n):
		var a = Node2D.new()
		a.name = "Orbit"
		orbit_root.add_child(a)
		orbit_children.append(a)
	orbit_angle = 0.0

func _rotate_orbit(delta: float) -> void:
	orbit_angle += delta * 2.5
	var storm = _has_flag("orbit_storm")
	var R = 70.0 * effective_area() * (1.4 if storm else 1.0)
	var n = orbit_children.size()
	var crit_bonus = _flag_value("crit_up")
	for i in range(n):
		var ang = orbit_angle + i * TAU / max(1, n)
		var cpos = player.global_position + Vector2(cos(ang), sin(ang)) * R
		orbit_children[i].global_position = cpos
		# 手动命中检测（环绕每 0.4s 对同一敌人结算一次）
		var uids = EnemyManager.query_near(cpos, 16.0)
		for uid in uids:
			var now = GameManager.run_time
			if orbit_hit_cd.has(uid) and now - orbit_hit_cd[uid] < 0.4:
				continue
			orbit_hit_cd[uid] = now
			var dmg = effective_damage() * (1.5 if storm else 1.0)
			EnemyManager.take_damage(uid, dmg, Vector2.ZERO, 0.0, player, effective_shield_pen(), crit_bonus)
			AffixManager.apply_weapon_hit(_wid(), uid, dmg, player)

## 横扫（sweep）：以玩家为中心持续旋转的刀光线段（直径），命中落在
## 线段上的敌人；每个敌人有独立冷却，故随刀光转一圈会周期性触发一次。
## 满足需求：巨剑等“横扫”武器 = 线段上敌人全受伤害 + 一段时间触发一次的技能。
func _rotate_sweep(delta: float) -> void:
	var speed = float(data.get("sweep_speed", 3.0))   # rad/s，数值越大横扫越快
	sweep_angle += delta * speed
	var R = 90.0 * effective_area() * float(data.get("sweep_range", 1.0))
	var half_w = float(data.get("sweep_width", 24.0))  # 线段半宽（命中容差）
	var d = Vector2(cos(sweep_angle), sin(sweep_angle))
	var uids = EnemyManager.query_near(global_position, R + 40.0)
	var now = GameManager.run_time
	var crit_bonus = _flag_value("crit_up")
	var kb = float(data.knockback)
	for uid in uids:
		var ep = EnemyManager.get_enemy_pos(uid)
		if ep == Vector2.ZERO:
			continue
		var rel = ep - global_position
		var proj = rel.dot(d)
		if proj < -R or proj > R:
			continue                       # 不在线段长度范围内
		var perp = abs(rel.x * d.y - rel.y * d.x)
		if perp > half_w:
			continue                       # 离刀光线段太远
		if sweep_hit_cd.has(uid) and now - sweep_hit_cd[uid] < 0.5:
			continue                       # 同一敌人 0.5s 内不重复受击
		sweep_hit_cd[uid] = now
		var dmg = effective_damage()
		var kdir = rel.normalized()
		EnemyManager.take_damage(uid, dmg, kdir, kb, player, effective_shield_pen(), crit_bonus)
		AffixManager.apply_weapon_hit(_wid(), uid, dmg, player)

## ---- 外观（数据驱动，统一交由 WeaponVisual 渲染）----
## 每把武器的专属特效都在 scripts/systems/weapon_visual.gd，由 data.visual.shape 选择分支。
## 约定：shape 必须全局唯一且被 WeaponVisual 支持（见 smoke_check._check_weapon_fx）。
func _draw() -> void:
	if not GameManager.playing:
		return
	var visual = _visual_with_tier()
	var shape = str(visual.get("shape", ""))
	if data.type == "aura":
		WeaponVisual.draw_aura(self, shape, 80.0 * effective_area(), visual)
	elif data.type == "orbit":
		var off = -global_position
		for c in orbit_children:
			WeaponVisual.draw_orbit(self, shape, c.global_position + off, visual, orbit_angle)
	elif data.type == "sweep":
		var R = 90.0 * effective_area() * float(data.get("sweep_range", 1.0))
		var d = Vector2(cos(sweep_angle), sin(sweep_angle))
		WeaponVisual.draw_sweep(self, shape, d, R, visual)
