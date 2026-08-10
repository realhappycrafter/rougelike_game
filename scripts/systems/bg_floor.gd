extends Node2D
## 暗黑地牢地面：取代纯色 ColorRect。
## 在 _draw 里一次性绘制（绘制指令缓存，不每帧重画）：
##   1) 深紫褐底色  2) 细网格 + 每 400px 的亮色主网格  3) 随机噪声点（裂纹/苔痕）
##   4) 发光地图边界框（玩家可清晰看见可走区域边缘）。
## 静态绘制，约 100 条线 + 500 点，开销可忽略。

var map_w = 3200.0
var map_h = 2400.0
var _specks = []

# 可配置配色（由 main.gd 按当前地图注入；默认暗黑地牢紫褐调）
var floor_base = Color(0.08, 0.06, 0.10)
var floor_grid = Color(0.15, 0.12, 0.20)
var floor_border = Color(0.62, 0.30, 0.58)

func _ready() -> void:
	seed(0x5eed)
	var hw = map_w / 2.0
	var hh = map_h / 2.0
	for i in range(520):
		var r = randf_range(1.5, 4.0)
		var base = Color(randf_range(0.10, 0.20), randf_range(0.08, 0.15), randf_range(0.13, 0.22), 1.0)
		_specks.append({ "x": randf_range(-hw, hw), "y": randf_range(-hh, hh), "r": r, "c": base })
	queue_redraw()

func _draw() -> void:
	var hw = map_w / 2.0
	var hh = map_h / 2.0
	var tl = Vector2(-hw, -hh)
	# 1) 底色
	draw_rect(Rect2(tl, Vector2(map_w, map_h)), floor_base)
	# 2a) 细网格
	var step = 80.0
	for x in range(int(-hw), int(hw) + 1, int(step)):
		draw_line(Vector2(x, -hh), Vector2(x, hh), floor_grid, 1.0)
	for y in range(int(-hh), int(hh) + 1, int(step)):
		draw_line(Vector2(-hw, y), Vector2(hw, y), floor_grid, 1.0)
	# 2b) 主网格（更亮）
	for x in range(int(-hw), int(hw) + 1, 400):
		draw_line(Vector2(x, -hh), Vector2(x, hh), floor_grid.lightened(0.12), 2.0)
	for y in range(int(-hh), int(hh) + 1, 400):
		draw_line(Vector2(-hw, y), Vector2(hw, y), floor_grid.lightened(0.12), 2.0)
	# 3) 噪声点
	for s in _specks:
		draw_circle(Vector2(s.x, s.y), s.r, s.c)
	# 4) 发光边界框
	var fr = Rect2(tl, Vector2(map_w, map_h))
	draw_rect(fr.grow(-3.0), floor_border.darkened(0.25), false, 3.0)
	draw_rect(fr, floor_border, false, 6.0)
