extends Node2D
## Gem —— 掉落物（GDD §7）
## 类型：exp（经验）/ coin（金币）/ heal（治疗）/ magnet（全屏吸附）。
## 进入拾取范围后加速飞向玩家；magnet 触发后所有宝石强制追踪。

var main = null
var type = "exp"
var value = 0
var alive = false
var homing = false

func spawn(pos: Vector2, t: String, v: int, m) -> void:
	global_position = pos
	type = t
	value = v
	main = m
	alive = true
	homing = false
	visible = true
	add_to_group("gems")
	queue_redraw()

func _draw():
	if not alive:
		return
	var c = Color(0.3, 1, 0.6)
	match type:
		"exp":    c = Color(0.3, 1, 0.6)
		"coin":   c = Color(1, 0.85, 0.2)
		"heal":   c = Color(1, 0.4, 0.5)
		"magnet": c = Color(0.4, 0.7, 1)
	draw_circle(Vector2.ZERO, 5.0, c)

func _process(delta: float) -> void:
	if not alive or not GameManager.playing:
		return
	var p = GameManager.player
	if p == null:
		return
	var d = global_position.distance_to(p.global_position)
	var pr = p.pickup_range
	if homing or d < pr:
		var dir = (p.global_position - global_position).normalized()
		var sp = 700.0 if homing else lerp(140.0, 600.0, 1.0 - clamp(d / pr, 0.0, 1.0))
		global_position += dir * sp * delta
	if d < 14.0:
		collect()

func collect() -> void:
	if not alive:
		return
	alive = false
	match type:
		"exp":
			GameManager.add_exp(value)
		"coin":
			GameManager.gold += int(round(float(value) * GameManager.meta_gold_mult))
		"heal":
			if GameManager.player:
				var pl = GameManager.player
				pl.hp = min(pl.max_hp, pl.hp + pl.max_hp * 0.1)
		"magnet":
			for gm in get_tree().get_nodes_in_group("gems"):
				gm.homing = true
	visible = false
	remove_from_group("gems")
	if main and main.has_method("return_gem"):
		main.return_gem(self)
