extends Node2D
## RemoteWorld —— 客机端世界渲染器（仅读取快照，不做任何模拟）
## 把 host 广播的 state 快照里的「敌人」与「其他玩家」画出来。
## 本端玩家由真实 player 节点自绘（位置由 main 的客户端预测/插值驱动）。

var enemy_list: Array = []     # host 快照中的敌人紧凑数组
var player_list: Array = []    # 其他玩家（不含自己）的紧凑数组
var self_pid: int = -1

func _draw() -> void:
	# ---- 敌人（与 EnemyRender 视觉对齐：暗描边 + 主体 + 受击/暴击/血条）----
	for e in enemy_list:
		var col = Color(e.c[0], e.c[1], e.c[2], 1.0)
		var pos = Vector2(float(e.x), float(e.y))
		var s = float(e.s)
		draw_circle(pos, s, col.darkened(0.2))
		draw_circle(pos, s * 0.8, col)
		if float(e.f) > 0.0:
			draw_circle(pos, s, Color(1, 1, 1, float(e.f)))
		if float(e.cr) > 0.0:
			var k = float(e.cr) / 0.18
			draw_circle(pos, s * (1.0 + 0.4 * k), Color(1, 1, 1, 0.55 * k))
		if int(e.b) == 1 or int(e.el) == 1:
			var w = max(30.0, s * 2.0)
			var ratio = clamp(float(e.hp) / float(e.m), 0.0, 1.0)
			draw_rect(Rect2(pos.x - w / 2.0, pos.y - s - 8.0, w, 4.0), Color(0.2, 0.2, 0.2, 0.8))
			draw_rect(Rect2(pos.x - w / 2.0, pos.y - s - 8.0, w * ratio, 4.0), Color(0.9, 0.2, 0.2, 0.9))

	# ---- 其他玩家（身份环颜色 + 简单身体 + 血条）----
	for p in player_list:
		var col = Color(0.45, 0.8, 1.0)
		if p.has("c"):
			col = Color(p.c[0], p.c[1], p.c[2], 1.0)
		var pos = Vector2(float(p.x), float(p.y))
		var r = 14.0
		draw_circle(pos + Vector2(0, r * 0.75), r * 0.85, Color(0, 0, 0, 0.30))
		draw_circle(pos, r, col.darkened(0.3))
		draw_circle(pos, r * 0.7, col)
		if p.has("hp") and p.has("mhp"):
			var ratio = clamp(float(p.hp) / float(p.mhp), 0.0, 1.0)
			draw_rect(Rect2(pos.x - 14.0, pos.y - r - 8.0, 28.0, 3.0), Color(0.2, 0.2, 0.2, 0.8))
			draw_rect(Rect2(pos.x - 14.0, pos.y - r - 8.0, 28.0 * ratio, 3.0), Color(0.3, 0.9, 0.4, 0.9))
