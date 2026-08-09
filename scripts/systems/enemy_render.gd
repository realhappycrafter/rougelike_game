extends Node2D
## EnemyRender —— 敌人批量绘制表面（挂在 world 下，随相机变换）
## 数据由 EnemyManager 持有，这里只负责把存活敌人画成圆（单 CanvasItem、批量绘制）。
## 取代原本每个敌人一个 Area2D 的 _draw，把 800 次节点绘制降到 1 个绘制表面。

func _draw() -> void:
	if Engine.is_editor_hint():
		return
	if EnemyManager != null:
		EnemyManager.draw_obstacles(self)
		EnemyManager.draw_enemies(self)

func _process(_delta: float) -> void:
	# Godot 4 中 _draw 不会每帧自动重绘：绘制指令在第一次 _draw 时生成并缓存，
	# 之后敌人位置/数量变化不会自动反映。必须主动 queue_redraw() 才能持续刷新画面。
	# 仅在游戏进行中重绘（暂停/菜单时保留上一帧画面即可，无需重画）。
	if Engine.is_editor_hint():
		return
	if GameManager != null and GameManager.playing:
		queue_redraw()
