extends Node2D
## RemoteWorld —— 客机端世界渲染器（仅读取快照，不做任何模拟）
## 把 host 广播的 state 快照里的「敌人」「其他玩家」「掉落物（宝石/宝箱）」画出来。
## 本端玩家由真实 player 节点自绘（位置由 main 的客户端预测/插值驱动）。

var enemy_list: Array = []     # host 快照中的敌人紧凑数组
var player_list: Array = []    # 其他玩家（不含自己）的紧凑数组
var gem_list: Array = []       # host 快照中的宝石掉落数组（{x,y,ty}）
var chest_list: Array = []     # host 快照中的宝箱掉落数组（{x,y,q}）
var self_pid: int = -1

# 宝石按类型着色（与 gem.gd 一致）
const GEM_COLORS = {
	"exp": Color(0.3, 1.0, 0.6),
	"coin": Color(1.0, 0.85, 0.2),
	"heal": Color(1.0, 0.4, 0.5),
	"magnet": Color(0.4, 0.7, 1.0)
}
# 宝箱按品质着色（与 chest.gd QUALITY_HTML 一致）：白/绿/蓝/紫/金/红
const CHEST_COLORS = [
	Color(0.91, 0.91, 0.91),
	Color(0.30, 0.69, 0.31),
	Color(0.13, 0.59, 0.95),
	Color(0.61, 0.15, 0.69),
	Color(1.0, 0.76, 0.03),
	Color(0.96, 0.26, 0.21)
]

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

	# ---- 掉落物：宝石（按 type 着色）----
	for g in gem_list:
		var gc = GEM_COLORS.get(str(g.get("ty", "exp")), GEM_COLORS["exp"])
		var pos = Vector2(float(g.x), float(g.y))
		draw_circle(pos, 5.0, gc)

	# ---- 掉落物：宝箱（按品质着色，框线 + 高光，与 chest.gd 视觉对齐）----
	for c in chest_list:
		var q = int(c.get("q", 0))
		var cc = CHEST_COLORS[q] if q >= 0 and q < CHEST_COLORS.size() else Color.GOLD
		var pos = Vector2(float(c.x), float(c.y))
		draw_rect(Rect2(pos.x - 18.0, pos.y - 16.0, 36.0, 32.0), cc)
		draw_rect(Rect2(pos.x - 18.0, pos.y - 16.0, 36.0, 32.0), Color(0.12, 0.10, 0.04, 0.9), false, 3.0)
		draw_rect(Rect2(pos.x - 9.0, pos.y - 7.0, 18.0, 14.0), Color(1.0, 1.0, 1.0, 0.5))

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
