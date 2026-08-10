extends Area2D
## Projectile —— 武器弹道（GDD §4.1 投射物）
## 对象池复用。命中改为查询 EnemyManager（数据驱动 + 空间哈希），
## 不再依赖物理信号，pierce 决定穿透次数。

var main = null
var vel = Vector2.ZERO
var damage = 0.0
var pierce = 0
var knockback = 0.0
var life = 0.0
var hit_set = []   # 已命中敌人 uid
var visual = {}     # 外观描述 {"shape":, "color":}
var owner_player = null  # 发射此弹的玩家（暴击/吸血归属）

func launch(pos: Vector2, v: Vector2, dmg: float, pc: int, kback: float, life_t: float, m, owner = null, visual_data = {}) -> void:
	global_position = pos
	vel = v
	damage = dmg
	pierce = pc
	knockback = kback
	life = life_t
	main = m
	owner_player = owner
	visual = visual_data
	rotation = v.angle()   # 朝飞行方向（飞镖类外观据此旋转）
	visible = true
	hit_set = []
	queue_redraw()

## 从 visual 读颜色（[r,g,b] 数组），缺省用兜底色
func _vc(key: String, fallback: Color) -> Color:
	if visual.has(key):
		var c = visual[key]
		if typeof(c) == TYPE_ARRAY and c.size() >= 3:
			return Color(c[0], c[1], c[2])
	return fallback

## 弹体已按飞行方向 rotation 旋转，故绘制一律以 +X 为前方
func _draw():
	if not visible:
		return
	var col = _vc("color", Color(1, 0.9, 0.3))
	var col2 = _vc("color2", Color(1, 1, 1))
	match visual.get("shape", "dot"):
		"dart":
			# 飞刀：三角飞镖
			draw_colored_polygon(
				PackedVector2Array([Vector2(9, 0), Vector2(-6, -5), Vector2(-3, 0), Vector2(-6, 5)]), col)
			draw_circle(Vector2(-2, 0), 2.0, Color(col2.r, col2.g, col2.b, 0.9))
		"bolt":
			# 魔弹：核心 + 光晕
			draw_circle(Vector2.ZERO, 8.0, Color(col.r, col.g, col.b, 0.45))
			draw_circle(Vector2.ZERO, 4.5, col)
			draw_circle(Vector2.ZERO, 2.0, col2)
		"arrow":
			# 弩箭：细杆 + 箭头 + 尾羽
			draw_line(Vector2(-10, 0), Vector2(6, 0), col, 2.5)
			draw_colored_polygon(
				PackedVector2Array([Vector2(12, 0), Vector2(4, -4), Vector2(4, 4)]), col2)
			draw_line(Vector2(-10, -3), Vector2(-6, 0), col2, 1.5)
			draw_line(Vector2(-10, 3), Vector2(-6, 0), col2, 1.5)
		"feather":
			# 凤凰火羽：火焰羽翎 + 拖尾
			draw_colored_polygon(
				PackedVector2Array([Vector2(11, 0), Vector2(0, -6), Vector2(-8, 0), Vector2(0, 6)]),
				Color(col.r, col.g, col.b, 0.95))
			draw_colored_polygon(
				PackedVector2Array([Vector2(6, 0), Vector2(0, -3), Vector2(-4, 0), Vector2(0, 3)]), col2)
			draw_line(Vector2(-8, 0), Vector2(-16, 0), Color(col.r, col.g, col.b, 0.35), 4.0)
		"sword":
			# 飞剑：细长剑身 + 剑格
			draw_line(Vector2(-12, 0), Vector2(13, 0), col, 3.0)
			draw_line(Vector2(-6, -5), Vector2(-6, 5), col2, 2.0)
			draw_circle(Vector2(13, 0), 2.5, col2)
		"thunder":
			# 雷法：锯齿闪电
			draw_polyline(PackedVector2Array([
				Vector2(-12, 0), Vector2(-4, -6), Vector2(0, 1), Vector2(6, -5), Vector2(12, 2)
			]), col, 3.0)
			draw_circle(Vector2(12, 2), 3.5, Color(col2.r, col2.g, col2.b, 0.9))
		"talisman_shot":
			# 符箓：矩形符纸 + 符文
			draw_rect(Rect2(Vector2(-5, -8), Vector2(10, 16)), col)
			draw_rect(Rect2(Vector2(-5, -8), Vector2(10, 16)), col2, false, 1.5)
			draw_line(Vector2(0, -5), Vector2(0, 5), col2, 1.5)
			draw_line(Vector2(-3, 0), Vector2(3, 0), col2, 1.5)
		_:
			draw_circle(Vector2.ZERO, 6.0, col)

func _physics_process(delta: float) -> void:
	if not GameManager.playing or not visible:
		return
	global_position += vel * delta
	life -= delta
	queue_redraw()   # 弹体每帧移动，需重绘以更新位置
	# 手动命中检测：查询附近敌人（含其半径）
	var uids = EnemyManager.query_near(global_position, 8.0)
	for uid in uids:
		if hit_set.has(uid):
			continue
		hit_set.append(uid)
		EnemyManager.take_damage(uid, damage, vel.normalized(), knockback, owner_player)
		if pierce <= 0:
			retire()
			return
		else:
			pierce -= 1
	if life <= 0:
		retire()

func retire() -> void:
	visible = false
	if main and main.has_method("return_projectile"):
		main.return_projectile(self)
