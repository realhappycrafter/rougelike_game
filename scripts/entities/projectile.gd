extends Area2D
const WeaponVisual = preload("res://scripts/systems/weapon_visual.gd")
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

## 弹体已按飞行方向 rotation 旋转，故绘制一律以 +X 为前方
## 专属外观全部交由 WeaponVisual.draw_projectile（按 visual.shape 分支）。
func _draw():
	if not visible:
		return
	WeaponVisual.draw_projectile(self, visual)

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
