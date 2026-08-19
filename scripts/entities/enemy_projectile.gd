extends Area2D
## EnemyProjectile —— 敌方弹体（远程怪/咒术师发射的弹幕）
## host 权威生成与命中判定（与玩家弹体同源：手动邻近查询，不用物理信号），
## 命中任一 combat_players（含客机代理）即结算伤害并回收。
## 不入快照广播：本端世界由 host 模拟，伤害统一应用到全部 combat_players。

var main = null
var vel = Vector2.ZERO
var damage = 0.0
var life = 0.0
const MAX_LIFE = 3.0
var _color = Color(1, 1, 1)

func launch(pos: Vector2, dir: Vector2, sp: float, dmg: float, col: Color, m) -> void:
	main = m
	global_position = pos
	vel = dir.normalized() * sp
	damage = dmg
	_color = col
	life = MAX_LIFE
	visible = true
	queue_redraw()

func _draw():
	if not visible:
		return
	# 敌弹外观：发光圆点 + 亮核（与玩家弹的飞镖/弓簇显著区分）
	draw_circle(Vector2.ZERO, 7.0, Color(_color.r, _color.g, _color.b, 0.45))
	draw_circle(Vector2.ZERO, 4.0, _color)
	draw_circle(Vector2.ZERO, 2.0, Color(1, 1, 1, 0.95))

func _physics_process(delta):
	if not GameManager.playing or not visible:
		return
	global_position += vel * delta
	life -= delta
	queue_redraw()
	# 手动命中判定：查询附近玩家（含其碰撞半径）
	var players = GameManager.get_players_for_combat()
	for pl in players:
		if not is_instance_valid(pl):
			continue
		if global_position.distance_to(pl.global_position) <= 8.0 + pl.body_radius:
			pl.take_damage(damage)
			retire()
			return
	if life <= 0:
		retire()

func retire():
	visible = false
	if main != null and main.has_method("return_enemy_projectile"):
		main.return_enemy_projectile(self)
