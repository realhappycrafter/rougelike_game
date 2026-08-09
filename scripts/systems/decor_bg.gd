extends Control
## 装饰性背景（菜单/标题用）：暗黑地牢风格。
## 一次性 _draw：底色 + 中央辉光（同心圆近似）+ 细网格 + 四边暗角。
## 在 menu.gd 中作为第一个子节点（最底层），覆盖整个视口。

var base = Color(0.07, 0.05, 0.10)
var glow = Color(0.30, 0.14, 0.30)
var glow_pos = Vector2(0.5, 0.26)   # 归一化坐标（标题附近）
var grid = true

func _ready() -> void:
	queue_redraw()

func _draw() -> void:
	var sz = get_viewport_rect().size
	# 底色
	draw_rect(Rect2(0, 0, sz.x, sz.y), base)
	# 中央辉光（同心圆近似径向渐变）
	var c = Vector2(glow_pos.x * sz.x, glow_pos.y * sz.y)
	var maxr = max(sz.x, sz.y) * 0.62
	for i in range(44):
		var t = float(i) / 44.0
		draw_circle(c, lerp(50.0, maxr, t), Color(glow.r, glow.g, glow.b, (1.0 - t) * 0.085))
	# 细网格
	if grid:
		for x in range(0, int(sz.x), 64):
			draw_line(Vector2(x, 0), Vector2(x, sz.y), Color(0.18, 0.14, 0.24, 0.35), 1.0)
		for y in range(0, int(sz.y), 64):
			draw_line(Vector2(0, y), Vector2(sz.x, y), Color(0.18, 0.14, 0.24, 0.35), 1.0)
	# 四边暗角（边缘渐暗）
	var band = 130.0
	for i in range(int(band)):
		var a = (1.0 - float(i) / band) * 0.045
		draw_rect(Rect2(0, i, sz.x, 1), Color(0, 0, 0, a))
		draw_rect(Rect2(0, sz.y - 1 - i, sz.x, 1), Color(0, 0, 0, a))
		draw_rect(Rect2(i, 0, 1, sz.y), Color(0, 0, 0, a))
		draw_rect(Rect2(sz.x - 1 - i, 0, 1, sz.y), Color(0, 0, 0, a))
