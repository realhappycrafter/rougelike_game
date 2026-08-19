class_name AffixVisual
extends Control
## AffixVisual —— 词条专属徽记渲染器（质变 / 超质变 / 怪物黑色词条）
##
## 设计约定（2026-08-16 落地）：
##   1) 每个词条在 data/*.json 的 visual.shape 必须落在 SHAPES 之内（s0..s15），
##      由 smoke_check._check_affixes 校验「无未知 shape」。
##   2) 同一武器的 质变(mutation) 与 超质变(super) 共用一个 shape，
##      超质变通过 is_super=true 叠加外旋光环 + 光芒，视觉上更夸张。
##   3) 怪物黑色词条颜色偏暗（近黑），用 lightened 后的描边保证在暗底上仍可见。
##   4) 既可作为 Control 实例直接挂到 UI（set_affix + 设 custom_minimum_size），
##      也可静态调用 draw_emblem 在任意 CanvasItem 上绘制。

const SHAPES := ["s0","s1","s2","s3","s4","s5","s6","s7","s8","s9","s10","s11","s12","s13","s14","s15"]

## 返回受支持的所有 shape
static func shape_list() -> Array:
	return SHAPES.duplicate()

static func supports(s: String) -> bool:
	return SHAPES.has(s)

# ---- 实例属性（作为 Control 用时由 set_affix 填充）----
var shape: String = "s0"
var col: Color = Color(0.5, 0.8, 1.0)
var is_super: bool = false
var radius: float = 18.0

## 从词条字典填充属性（兼容 mutation / monster 两类数据：color + visual.{shape,super}）
func set_affix(a: Dictionary) -> void:
	var vis = a.get("visual", {})
	shape = str(vis.get("shape", "s0"))
	is_super = bool(vis.get("super", false))
	var carr = a.get("color", [0.5, 0.8, 1.0])
	if typeof(carr) == TYPE_ARRAY and carr.size() >= 3:
		col = Color(float(carr[0]), float(carr[1]), float(carr[2]))
	else:
		col = Color(0.5, 0.8, 1.0)
	queue_redraw()

func _draw() -> void:
	if not SHAPES.has(shape):
		shape = "s0"
	draw_emblem(self, shape, col, is_super, radius, Time.get_ticks_msec() / 1000.0)

## =====================================================================
## 核心绘制：在 CanvasItem c 上以原点为中心画一个词条徽记
## =====================================================================
static func draw_emblem(c: CanvasItem, shape: String, col: Color, is_super: bool, radius: float, t: float) -> void:
	var col2 = col.lightened(0.45)
	# 暗色词条（黑词条）提亮描边，保证在暗底可见
	if col.r + col.g + col.b < 0.55:
		col2 = Color(max(col.r, 0.35), max(col.g, 0.30), max(col.b, 0.38))
	# 柔光底
	c.draw_circle(Vector2.ZERO, radius * 1.08, Color(col.r, col.g, col.b, 0.10))
	c.draw_circle(Vector2.ZERO, radius * 0.62, Color(col.r, col.g, col.b, 0.09))

	match shape:
		"s0":  # 爆裂碎片：四角火花
			var pts = PackedVector2Array()
			for i in range(8):
				var ang = i * PI / 4.0
				var rr = radius * (1.0 if i % 2 == 0 else 0.42)
				pts.append(Vector2(cos(ang), sin(ang)) * rr)
			c.draw_colored_polygon(pts, col)
			c.draw_circle(Vector2.ZERO, radius * 0.22, col2)
		"s1":  # 闪电：锯齿
			var pts = PackedVector2Array([
				Vector2(-radius*0.2, -radius), Vector2(-radius*0.5, 0),
				Vector2(0, 0), Vector2(-radius*0.25, radius),
				Vector2(radius*0.5, -radius*0.1), Vector2(0, -radius*0.1),
				Vector2(radius*0.25, -radius)
			])
			c.draw_colored_polygon(pts, col)
			c.draw_polyline(pts, Color(col2.r, col2.g, col2.b, 0.8), 1.5)
		"s2":  # 火焰：水滴火苗
			c.draw_colored_polygon(PackedVector2Array([
				Vector2(0, -radius), Vector2(radius*0.55, radius*0.2),
				Vector2(0, radius), Vector2(-radius*0.55, radius*0.2)]), col)
			c.draw_colored_polygon(PackedVector2Array([
				Vector2(0, -radius*0.4), Vector2(radius*0.28, radius*0.3),
				Vector2(0, radius*0.5), Vector2(-radius*0.28, radius*0.3)]), col2)
		"s3":  # 诅咒骷髅：圆颅 + 双眼 + 颌
			c.draw_circle(Vector2.ZERO, radius*0.72, col)
			c.draw_circle(Vector2(-radius*0.28, -radius*0.12), radius*0.18, Color(0.05,0.05,0.07))
			c.draw_circle(Vector2(radius*0.28, -radius*0.12), radius*0.18, Color(0.05,0.05,0.07))
			c.draw_rect(Rect2(Vector2(-radius*0.4, radius*0.3), Vector2(radius*0.8, radius*0.18)), col2)
			c.draw_line(Vector2(-radius*0.15, radius*0.3), Vector2(-radius*0.15, radius*0.48), Color(0.05,0.05,0.07), 1.5)
			c.draw_line(Vector2(radius*0.15, radius*0.3), Vector2(radius*0.15, radius*0.48), Color(0.05,0.05,0.07), 1.5)
		"s4":  # 破盾：盾形 + 裂痕
			c.draw_colored_polygon(PackedVector2Array([
				Vector2(-radius*0.7, -radius*0.7), Vector2(radius*0.7, -radius*0.7),
				Vector2(radius*0.7, radius*0.2), Vector2(0, radius*0.85),
				Vector2(-radius*0.7, radius*0.2)]), col)
			c.draw_line(Vector2(0, -radius*0.5), Vector2(-radius*0.15, 0), Color(0.05,0.05,0.07), 2.0)
			c.draw_line(Vector2(-radius*0.15, 0), Vector2(radius*0.2, radius*0.45), Color(0.05,0.05,0.07), 2.0)
		"s5":  # 贯穿：竖直箭/矛
			c.draw_line(Vector2(0, -radius), Vector2(0, radius*0.7), col, 3.0)
			c.draw_colored_polygon(PackedVector2Array([
				Vector2(0, -radius), Vector2(-radius*0.32, -radius*0.45),
				Vector2(radius*0.32, -radius*0.45)]), col2)
			c.draw_line(Vector2(-radius*0.4, radius*0.7), Vector2(radius*0.4, radius*0.7), col2, 2.0)
			c.draw_line(Vector2(-radius*0.25, radius*0.5), Vector2(radius*0.25, radius*0.5), col2, 1.5)
		"s6":  # 剧毒：液滴
			c.draw_colored_polygon(PackedVector2Array([
				Vector2(0, -radius), Vector2(radius*0.6, radius*0.1),
				Vector2(0, radius), Vector2(-radius*0.6, radius*0.1)]), col)
			c.draw_circle(Vector2(0, radius*0.25), radius*0.32, col2)
		"s7":  # 冰霜：六角雪晶
			for i in range(6):
				var ang = i * PI / 3.0 + t * 0.5
				var tip = Vector2(cos(ang), sin(ang)) * radius
				c.draw_line(Vector2.ZERO, tip, col, 2.4)
				var mid = tip * 0.55
				var perp = Vector2(-sin(ang), cos(ang)) * radius * 0.22
				c.draw_line(mid, mid + perp, col2, 1.8)
				c.draw_line(mid, mid - perp, col2, 1.8)
			c.draw_circle(Vector2.ZERO, radius*0.16, col2)
		"s8":  # 凝视/增殖：眼
			c.draw_ellipse(Vector2.ZERO, radius*0.85, radius*0.5, col, true, 2.0)
			c.draw_circle(Vector2.ZERO, radius*0.3, Color(0.05, 0.05, 0.07))
			c.draw_circle(Vector2.ZERO, radius*0.18, col2)
		"s9":  # 嗜血：血滴 + 獠牙
			c.draw_colored_polygon(PackedVector2Array([
				Vector2(0, -radius), Vector2(radius*0.45, radius*0.1),
				Vector2(0, radius*0.7), Vector2(-radius*0.45, radius*0.1)]), col)
			c.draw_circle(Vector2(0, radius*0.2), radius*0.22, col2)
			c.draw_colored_polygon(PackedVector2Array([
				Vector2(-radius*0.3, radius*0.4), Vector2(-radius*0.1, radius*0.4),
				Vector2(-radius*0.2, radius*0.8)]), col2)
			c.draw_colored_polygon(PackedVector2Array([
				Vector2(radius*0.3, radius*0.4), Vector2(radius*0.1, radius*0.4),
				Vector2(radius*0.2, radius*0.8)]), col2)
		"s10":  # 黄金：金币 + 星
			c.draw_circle(Vector2.ZERO, radius*0.8, col)
			c.draw_arc(Vector2.ZERO, radius*0.8, 0, TAU, 28, col2, 2.0)
			c.draw_circle(Vector2.ZERO, radius*0.5, Color(col.r*0.7, col.g*0.7, col.b*0.7))
			var sp = PackedVector2Array()
			for i in range(5):
				var a1 = -PI/2 + i * TAU/5
				var a2 = a1 + TAU/10
				sp.append(Vector2(cos(a1), sin(a1)) * radius*0.34)
				sp.append(Vector2(cos(a2), sin(a2)) * radius*0.15)
			c.draw_colored_polygon(sp, col2)
		"s11":  # 剑刃：竖剑
			c.draw_line(Vector2(0, -radius), Vector2(0, radius*0.45), col, 3.4)
			c.draw_line(Vector2(-radius*0.35, radius*0.45), Vector2(radius*0.35, radius*0.45), col2, 2.2)
			c.draw_line(Vector2(0, radius*0.45), Vector2(0, radius*0.85), col2, 3.0)
			c.draw_line(Vector2(-radius*0.5, -radius*0.1), Vector2(radius*0.5, -radius*0.1), col2, 1.6)
		"s12":  # 法阵：同心符环
			c.draw_arc(Vector2.ZERO, radius*0.9, 0, TAU, 32, col, 2.0)
			c.draw_arc(Vector2.ZERO, radius*0.55, t, t + PI*1.4, 24, col2, 2.0)
			for i in range(6):
				var a = i * PI/3.0
				var p = Vector2(cos(a), sin(a)) * radius*0.9
				c.draw_rect(Rect2(p - Vector2(1.6, 3.0), Vector2(3.2, 6.0)), col2)
		"s13":  # 利爪：三道爪痕
			for i in range(3):
				var off = (i - 1) * radius * 0.38
				c.draw_line(Vector2(off - radius*0.3, radius*0.6), Vector2(off + radius*0.3, -radius*0.6), col, 3.0)
				c.draw_line(Vector2(off - radius*0.3, radius*0.6), Vector2(off + radius*0.05, -radius*0.15), col2, 1.4)
		"s14":  # 星辰：五角星
			var sp = PackedVector2Array()
			for i in range(5):
				var a1 = -PI/2 + i * TAU/5
				var a2 = a1 + TAU/10
				sp.append(Vector2(cos(a1), sin(a1)) * radius)
				sp.append(Vector2(cos(a2), sin(a2)) * radius*0.42)
			c.draw_colored_polygon(sp, col)
			c.draw_circle(Vector2.ZERO, radius*0.12, col2)
		"s15":  # 漩涡：螺旋
			var pts = PackedVector2Array()
			for i in range(36):
				var a = i * 0.5 + t * 2.0
				var rr = radius * (i / 36.0)
				pts.append(Vector2(cos(a), sin(a)) * rr)
			c.draw_polyline(pts, col, 2.4)
			c.draw_circle(Vector2.ZERO, radius*0.16, col2)
		_:
			c.draw_circle(Vector2.ZERO, radius*0.7, col)
			c.draw_circle(Vector2.ZERO, radius*0.35, col2)

	# 超质变：外旋光环 + 光芒（更夸张）
	if is_super:
		var rr = radius * 1.3
		c.draw_arc(Vector2.ZERO, rr, t * 2.0, t * 2.0 + PI * 1.5, 30,
			Color(col2.r, col2.g, col2.b, 0.55), 2.2)
		c.draw_arc(Vector2.ZERO, rr * 0.85, -t * 1.5, -t * 1.5 + PI * 1.2, 26,
			Color(col2.r, col2.g, col2.b, 0.35), 1.4)
		for k in range(8):
			var a = t * 1.5 + k * TAU / 8.0
			var p1 = Vector2(cos(a), sin(a)) * radius * 0.95
			var p2 = Vector2(cos(a), sin(a)) * radius * 1.55
			c.draw_line(p1, p2, Color(col2.r, col2.g, col2.b, 0.7), 2.0)
