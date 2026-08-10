extends Node2D
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
	queue_redraw()   # 光环/环绕每帧需重绘（否则升级后半径/书页不刷新）

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

## ---- 外观（数据驱动）----
## 由 data.visual = {"shape": ..., "color": [r,g,b], "color2": [r,g,b]} 决定，
## 不再按武器 id 硬编码；新武器只需在 weapons.json 配 visual 即可有专属外观。
func _vis_color(key: String, fallback: Color) -> Color:
	var v = data.get("visual", {})
	if v.has(key):
		var c = v[key]
		if typeof(c) == TYPE_ARRAY and c.size() >= 3:
			return Color(c[0], c[1], c[2])
	return fallback

func _draw() -> void:
	if not GameManager.playing:
		return
	var shape = str(data.get("visual", {}).get("shape", ""))
	if data.type == "aura":
		_draw_aura(shape, 80.0 * effective_area())
	elif data.type == "orbit":
		var off = -global_position
		for c in orbit_children:
			_draw_orbit_item(shape, c.global_position + off)

## 光环类外观：以玩家为中心的范围表现
func _draw_aura(shape: String, r: float) -> void:
	var col = _vis_color("color", Color(0.30, 0.85, 0.35))
	var col2 = _vis_color("color2", col.lightened(0.3))
	match shape:
		"vine":
			# 蓝银草：多条缠绕藤蔓向外辐射
			draw_circle(Vector2.ZERO, r, Color(col.r, col.g, col.b, 0.10))
			for i in range(10):
				var a = orbit_angle * 0.4 + i * TAU / 10.0
				var tip = Vector2(cos(a), sin(a)) * r
				var mid = Vector2(cos(a + 0.5), sin(a + 0.5)) * r * 0.55
				draw_polyline(PackedVector2Array([Vector2.ZERO, mid, tip]),
					Color(col2.r, col2.g, col2.b, 0.75), 3.0)
			draw_arc(Vector2.ZERO, r, 0, TAU, 48, Color(col.r, col.g, col.b, 0.40), 2.0)
		"tower":
			# 七宝琉璃塔：七层同心光幕
			for i in range(7):
				var rr = r * (1.0 - i * 0.13)
				draw_arc(Vector2.ZERO, rr, 0, TAU, 40,
					Color(col.r, col.g, col.b, 0.16 + i * 0.05), 2.0)
			draw_circle(Vector2.ZERO, r * 0.16, Color(col2.r, col2.g, col2.b, 0.85))
		"landscape":
			# 山水画卷：卷轴状扇形水墨
			draw_circle(Vector2.ZERO, r, Color(col.r, col.g, col.b, 0.10))
			for i in range(5):
				var a0 = orbit_angle * 0.3 + i * TAU / 5.0
				draw_arc(Vector2.ZERO, r * (0.45 + i * 0.11), a0, a0 + PI * 0.7, 24,
					Color(col2.r, col2.g, col2.b, 0.5), 3.0)
		"talisman":
			# 符箓：外圈符文环 + 内层脉动
			draw_circle(Vector2.ZERO, r, Color(col.r, col.g, col.b, 0.09))
			draw_arc(Vector2.ZERO, r, 0, TAU, 48, Color(col.r, col.g, col.b, 0.5), 2.0)
			for i in range(8):
				var a = -orbit_angle * 0.6 + i * TAU / 8.0
				var p = Vector2(cos(a), sin(a)) * r * 0.82
				draw_rect(Rect2(p - Vector2(3, 5), Vector2(6, 10)),
					Color(col2.r, col2.g, col2.b, 0.85))
		_:
			# 兜底（含大蒜毒云）：双层雾 + 边缘环
			draw_circle(Vector2.ZERO, r, Color(col.r, col.g, col.b, 0.10))
			draw_circle(Vector2.ZERO, r * 0.66, Color(col2.r, col2.g, col2.b, 0.10))
			draw_arc(Vector2.ZERO, r, 0, TAU, 48, Color(col2.r, col2.g, col2.b, 0.45), 2.0)

## 环绕类外观：逐个环绕体各自绘制
func _draw_orbit_item(shape: String, p: Vector2) -> void:
	var col = _vis_color("color", Color(0.4, 0.8, 1.0))
	var col2 = _vis_color("color2", Color(0.85, 0.95, 1.0))
	match shape:
		"page":
			# 圣经：书页（矩形 + 高光）
			draw_rect(Rect2(p - Vector2(7, 9), Vector2(14, 18)), Color(col.r, col.g, col.b, 0.9))
			draw_rect(Rect2(p - Vector2(4, 6), Vector2(8, 12)), Color(col2.r, col2.g, col2.b, 0.95))
		"crescent":
			# 鞭子：新月弧刃（横扫）
			draw_arc(p, 17.0, orbit_angle, orbit_angle + PI * 0.85, 20,
				Color(col.r, col.g, col.b, 0.95), 4.0)
			draw_circle(p, 4.0, Color(col2.r, col2.g, col2.b, 0.9))
		"hammer":
			# 昊天锤：短柄 + 方形锤头
			var dir = Vector2(cos(orbit_angle), sin(orbit_angle))
			draw_line(p - dir * 10.0, p + dir * 4.0, Color(0.45, 0.32, 0.20), 4.0)
			var head = p + dir * 9.0
			draw_rect(Rect2(head - Vector2(9, 7), Vector2(18, 14)), Color(col.r, col.g, col.b, 0.95))
			draw_rect(Rect2(head - Vector2(9, 7), Vector2(18, 14)),
				Color(col2.r, col2.g, col2.b, 0.9), false, 2.0)
		"beast":
			# 柔骨兔：小兽身 + 长耳
			draw_circle(p, 8.0, Color(col.r, col.g, col.b, 0.95))
			draw_circle(p + Vector2(0, -9), 4.5, Color(col.r, col.g, col.b, 0.95))
			draw_line(p + Vector2(-3, -12), p + Vector2(-5, -21), Color(col2.r, col2.g, col2.b), 3.0)
			draw_line(p + Vector2(3, -12), p + Vector2(5, -21), Color(col2.r, col2.g, col2.b), 3.0)
		"treasure":
			# 法宝：旋转菱形 + 内核
			var a = orbit_angle * 2.0
			var pts = PackedVector2Array()
			for i in range(4):
				var t = a + i * TAU / 4.0
				pts.append(p + Vector2(cos(t), sin(t)) * 12.0)
			draw_colored_polygon(pts, Color(col.r, col.g, col.b, 0.9))
			draw_circle(p, 4.0, Color(col2.r, col2.g, col2.b, 1.0))
		"sword_array":
			# 万剑阵：细长剑体（指向切线方向）
			var dir2 = Vector2(cos(orbit_angle + PI / 2), sin(orbit_angle + PI / 2))
			var perp = Vector2(-dir2.y, dir2.x)
			draw_line(p - dir2 * 13.0, p + dir2 * 13.0, Color(col.r, col.g, col.b, 0.95), 3.0)
			draw_line(p - dir2 * 6.0 - perp * 5.0, p - dir2 * 6.0 + perp * 5.0,
				Color(col2.r, col2.g, col2.b, 0.9), 2.0)
			draw_circle(p + dir2 * 13.0, 2.5, Color(col2.r, col2.g, col2.b, 1.0))
		_:
			draw_circle(p, 14.0, Color(col.r, col.g, col.b, 0.85))
