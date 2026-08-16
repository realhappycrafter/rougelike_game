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
	var base = float(data.cooldown)
	base *= (1.0 - player.cooldown_reduction)
	return max(0.1, base)

func effective_damage() -> float:
	var d = float(data.damage) * _level_scaling() * (1.0 + player.damage_bonus)
	if evolved:
		d *= 2.5
	return d

func _level_scaling() -> float:
	return 1.0 + 0.15 * float(level - 1)

func effective_count() -> int:
	var c = int(data.count) + int((level - 1) / 3)
	if evolved and data.evolution == "infinite_knife":
		c += 5
	return max(1, c)

func effective_area() -> float:
	return float(data.area) * (1.0 + 0.05 * float(level - 1))

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
	cooldown_timer -= delta
	if cooldown_timer <= 0:
		cooldown_timer = effective_cooldown()
		fire()
	queue_redraw()   # 光环/环绕每帧重绘以驱动特效动画

func fire() -> void:
	match data.type:
		"projectile": _fire_projectile()
		"aura":       _fire_aura()
		"orbit":      pass  # orbit 由 _rotate_orbit 持续命中
		_:            _fire_projectile()

func _fire_projectile() -> void:
	var uid = EnemyManager.get_nearest(player.global_position)
	if uid < 0:
		return
	var target_pos = EnemyManager.get_enemy_pos(uid)
	if target_pos == Vector2.ZERO:
		return
	var base_dir = (target_pos - player.global_position).normalized()
	var n = effective_count()
	var spread = deg_to_rad(12)
	for i in range(n):
		var ang = base_dir.angle() + (i - (n - 1) / 2.0) * spread
		var dir = Vector2(cos(ang), sin(ang))
		var proj = main.get_projectile()
		if proj == null:
			return
		proj.launch(player.global_position + dir * 18.0, dir * float(data.projectile_speed),
			effective_damage(), int(data.pierce), float(data.knockback), 2.0, main, player, data.get("visual", {}))

func _fire_aura() -> void:
	var r = 80.0 * effective_area()
	var dmg = effective_damage()
	var uids = EnemyManager.query_near(global_position, r)
	for uid in uids:
		EnemyManager.take_damage(uid, dmg, Vector2.ZERO, 0.0, player)

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
	var R = 70.0 * effective_area()
	var n = orbit_children.size()
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
			EnemyManager.take_damage(uid, effective_damage(), Vector2.ZERO, 0.0, player)

## ---- 外观（数据驱动，统一交由 WeaponVisual 渲染）----
## 每把武器的专属特效都在 scripts/systems/weapon_visual.gd，由 data.visual.shape 选择分支。
## 约定：shape 必须全局唯一且被 WeaponVisual 支持（见 smoke_check._check_weapon_fx）。
func _draw() -> void:
	if not GameManager.playing:
		return
	var visual = data.get("visual", {})
	var shape = str(visual.get("shape", ""))
	if data.type == "aura":
		WeaponVisual.draw_aura(self, shape, 80.0 * effective_area(), visual)
	elif data.type == "orbit":
		var off = -global_position
		for c in orbit_children:
			WeaponVisual.draw_orbit(self, shape, c.global_position + off, visual, orbit_angle)
