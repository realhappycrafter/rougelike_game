class_name WeaponVisual
## WeaponVisual —— 武器专属特效集中渲染器（单一数据源）
## 设计约定（2026-08-16 起生效）：
##   1) 每把武器在 weapons.json 的 visual.shape 必须全局唯一，且必须在本文件的对应
##      match 分支里有专属绘制——不得多把武器共用一个兜底形状。
##   2) 三类行为各自一套分支：projectile / aura / orbit。
##   3) visual.fx（可选 Dictionary）提供通用氛围提示：
##        trail   (bool)   弹道拖尾（彗尾）
##        glow    (float)  外发光强度 0..1
##        spin    (float)  环绕体自转速度（rad/s，仅 orbit）
##        pulse   (float)  光环呼吸幅度 0..1
##        particles (String) 装饰粒子：ember/bubble/spark/leaf/mote/rune/ink/none
##        flicker (bool)   闪烁（雷/火）
##   4) smoke_check.gd 的 _check_weapon_fx 会校验：每把武器的 shape 都在 shape_list() 内、
##      类型匹配、且全局唯一——违反即 CI 失败，从机制上保证「新武器必须有专属特效」。

## 返回所有受支持形状：Array of [shape:String, category:String]
## category ∈ {"projectile","aura","orbit"}
static func shape_list() -> Array:
	return [
		["dart", "projectile"],
		["bolt", "projectile"],
		["arrow", "projectile"],
		["feather", "projectile"],
		["sword", "projectile"],
		["thunder", "projectile"],
		["poison", "aura"],
		["vine", "aura"],
		["tower", "aura"],
		["landscape", "aura"],
		["talisman", "aura"],
		["page", "orbit"],
		["crescent", "sweep"],
		["hammer", "sweep"],
		["beast", "orbit"],
		["treasure", "orbit"],
		["sword_array", "orbit"],
		["greatsword", "sweep"],
		["bowshot", "projectile"],
		["shield", "orbit"],
		["element_orb", "projectile"],
		["summon", "orbit"],
		["holy_circle", "aura"],
		["shieldbow", "projectile"],
	]

static func supports(shape: String) -> bool:
	for e in shape_list():
		if e[0] == shape:
			return true
	return false

static func category_of(shape: String) -> String:
	for e in shape_list():
		if e[0] == shape:
			return e[1]
	return ""

## ---- 颜色工具 ----
static func _c(visual: Dictionary, key: String, fallback: Color) -> Color:
	if visual.has(key):
		var v = visual[key]
		if typeof(v) == TYPE_ARRAY and v.size() >= 3:
			return Color(v[0], v[1], v[2])
	return fallback

static func _t() -> float:
	return Time.get_ticks_msec() / 1000.0

## 通用外发光（柔和大圆，低透明）
static func _glow(c: CanvasItem, pos: Vector2, radius: float, col: Color, strength: float) -> void:
	if strength <= 0.0:
		return
	c.draw_circle(pos, radius * 1.08, Color(col.r, col.g, col.b, 0.06 * strength))
	c.draw_circle(pos, radius * 0.7, Color(col.r, col.g, col.b, 0.05 * strength))

## 质变/超质变特效光环（叠加在武器特效之上，让质变一眼可见）：
##   mut   = 亮青脉冲环 + 绕体电星（质变专属辨识色）
##   super = 彩虹流转双环 + 多色星火 + 柔和彩晕（华丽震撼，与质变拉开档次）
static func _tier_glow(c: CanvasItem, tier: String, pos: Vector2, r: float, t: float) -> void:
	if tier == "mut":
		var a = 0.6 + 0.4 * sin(t * 6.0)
		c.draw_arc(pos, r + 6.0, t * 2.0, t * 2.0 + PI * 1.5, 28,
			Color(0.3, 0.9, 1.0, 0.55 * a), 2.5)
		c.draw_circle(pos, r * 0.7, Color(0.3, 0.9, 1.0, 0.08))
		for k in range(2):
			var sa = t * 7.0 + k * PI
			var sp = pos + Vector2(cos(sa), sin(sa)) * (r + 10.0)
			c.draw_circle(sp, 2.2, Color(1.0, 1.0, 1.0, 0.85))
	elif tier == "super":
		for ring_i in range(2):
			var hue = fmod(t * 1.8 + ring_i * 0.5, 1.0)
			var col = Color.from_hsv(hue, 0.9, 1.0)
			c.draw_arc(pos, r + 8.0 + ring_i * 4.0, t * 3.0 + ring_i * 2.0,
				t * 3.0 + ring_i * 2.0 + PI * 1.6, 30, Color(col.r, col.g, col.b, 0.5), 2.5)
		c.draw_circle(pos, r * 0.9, Color(1.0, 0.9, 0.6, 0.12))
		for k in range(4):
			var hue = fmod(t * 2.0 + float(k) * 0.25, 1.0)
			var col = Color.from_hsv(hue, 0.9, 1.0)
			var sa = t * 9.0 + k * PI / 2.0
			var sp = pos + Vector2(cos(sa), sin(sa)) * (r + 11.0)
			c.draw_circle(sp, 2.4, col)
			c.draw_circle(sp, 1.0, Color(1.0, 1.0, 1.0, 0.9))

## 装饰粒子（在半径 rr 内漂浮/上升）
static func _particles(c: CanvasItem, type: String, rr: float, col: Color, col2: Color, t: float) -> void:
	if type == "none" or type == "":
		return
	var n = 7
	for i in range(n):
		var seed = float(i) * 1.371 + 0.3
		var ang = t * (0.5 + fmod(seed, 1.0)) + seed * TAU
		var rad = rr * (0.35 + 0.5 * fmod(seed * 1.7, 1.0))
		var rise = fmod(t * 10.0 + seed * 13.0, rr)   # 上升位移（气泡/余烬用）
		var px = cos(ang) * rad
		var py = sin(ang) * rad
		var a = 0.45 * (0.4 + 0.6 * abs(sin(t * 2.0 + seed * 3.1)))
		match type:
			"ember":
				c.draw_circle(Vector2(px, py - rise * 0.5), 2.2, Color(col2.r, col2.g, col2.b, a))
			"bubble":
				c.draw_circle(Vector2(px, py - rise), 3.0, Color(col.r, col.g, col.b, a * 0.5))
				c.draw_circle(Vector2(px, py - rise), 1.4, Color(col2.r, col2.g, col2.b, a))
			"spark":
				c.draw_line(Vector2(px, py), Vector2(px + 3, py - 3), Color(col2.r, col2.g, col2.b, a), 1.5)
			"leaf":
				c.draw_circle(Vector2(px, py), 2.4, Color(col.r, col.g, col.b, a * 0.8))
				c.draw_circle(Vector2(px, py), 1.1, Color(col2.r, col2.g, col2.b, a))
			"mote":
				c.draw_circle(Vector2(px, py), 1.8, Color(col2.r, col2.g, col2.b, a))
			"rune":
				c.draw_rect(Rect2(Vector2(px - 1.5, py - 2.5), Vector2(3, 5)), Color(col2.r, col2.g, col2.b, a))
			"ink":
				c.draw_circle(Vector2(px, py), 3.2, Color(col.r, col.g, col.b, a * 0.4))
			_:
				c.draw_circle(Vector2(px, py), 2.0, Color(col.r, col.g, col.b, a))

# =====================================================================
# 弹道（projectile）：弹体已按飞行方向 rotation 旋转，绘制一律以 +X 为前方
# =====================================================================
static func draw_projectile(c: CanvasItem, visual: Dictionary) -> void:
	var col = _c(visual, "color", Color(1.0, 0.9, 0.3))
	var col2 = _c(visual, "color2", Color(1.0, 1.0, 1.0))
	var fx = visual.get("fx", {})
	var shape = str(visual.get("shape", "dot"))
	var t = _t()

	# 彗尾（朝飞行反方向 -X）
	if fx.get("trail", false):
		for i in range(6):
			var a = 0.55 - i * 0.085
			if a <= 0.0:
				break
			c.draw_line(Vector2(-i * 7.0, 0), Vector2(-(i + 1) * 7.0, 0),
				Color(col2.r, col2.g, col2.b, a * 0.6), 5.0 - i)

	match shape:
		"dart":  # 飞刀：金属三角镖 + 刃光 + 旋闪
			var glint = 0.6 + 0.4 * abs(sin(t * 18.0))
			c.draw_colored_polygon(PackedVector2Array([
				Vector2(11, 0), Vector2(-7, -5.5), Vector2(-3, 0), Vector2(-7, 5.5)]), col)
			c.draw_line(Vector2(-7, -5.5), Vector2(11, 0), Color(col2.r, col2.g, col2.b, glint), 1.5)
			c.draw_circle(Vector2(-2, 0), 2.0, Color(col2.r, col2.g, col2.b, 0.9))

		"bolt":  # 魔杖：蓄能法球 + 环绕符文 + 旋转光环 + 闪电碎弧
			var orb = 0.85 + 0.15 * sin(t * 8.0)
			c.draw_circle(Vector2.ZERO, 9.0, Color(col.r, col.g, col.b, 0.35 * orb))
			c.draw_circle(Vector2.ZERO, 4.8, col)
			c.draw_circle(Vector2.ZERO, 2.2, col2)
			for k in range(3):
				var a = t * 4.0 + k * TAU / 3.0
				var p = Vector2(cos(a), sin(a)) * 12.0
				c.draw_circle(p, 1.8, Color(col2.r, col2.g, col2.b, 0.9))
			c.draw_arc(Vector2.ZERO, 13.0, t * 3.0, t * 3.0 + PI * 1.4, 24,
				Color(col2.r, col2.g, col2.b, 0.35), 1.5)
			# 闪电碎弧：球体四周持续跳动的小锯齿电光（「法杖=闪电」一眼可见）
			for k in range(4):
				var sa = t * 16.0 + k * PI / 2.0
				var wob = sin(t * 33.0 + k * 2.1) * 3.0
				var pts = PackedVector2Array([
					Vector2(cos(sa) * 14.0, sin(sa) * 14.0),
					Vector2(cos(sa + 0.4) * (18.0 + wob), sin(sa + 0.4) * (18.0 + wob)),
					Vector2(cos(sa + 0.9) * 12.0, sin(sa + 0.9) * 12.0)])
				c.draw_polyline(pts, Color(0.5, 0.75, 1.0, 0.30), 3.0)
				c.draw_polyline(pts, Color(0.85, 0.95, 1.0, 0.9), 1.5)

		"arrow":  # 连珠弩：弩箭杆 + 箭头 + 能量尾线
			c.draw_line(Vector2(-11, 0), Vector2(6, 0), col, 2.6)
			c.draw_colored_polygon(PackedVector2Array([
				Vector2(13, 0), Vector2(4, -4.5), Vector2(4, 4.5)]), col2)
			c.draw_line(Vector2(-11, -3), Vector2(-7, 0), col2, 1.6)
			c.draw_line(Vector2(-11, 3), Vector2(-7, 0), col2, 1.6)
			c.draw_line(Vector2(-6, 0), Vector2(2, 0), Color(col2.r, col2.g, col2.b, 0.4), 1.0)

		"feather":  # 炽羽火线：火羽 + 抖动火焰 + 余烬
			var fl = 0.8 + 0.2 * sin(t * 16.0)
			c.draw_colored_polygon(PackedVector2Array([
				Vector2(12, 0), Vector2(0, -7 * fl), Vector2(-9, 0), Vector2(0, 7 * fl)]),
				Color(1.0, 0.55, 0.12, 0.95))
			c.draw_colored_polygon(PackedVector2Array([
				Vector2(7, 0), Vector2(0, -3.5 * fl), Vector2(-5, 0), Vector2(0, 3.5 * fl)]),
				Color(1.0, 0.9, 0.4, 0.95))
			c.draw_line(Vector2(-9, 0), Vector2(-17, 0), Color(1.0, 0.5, 0.1, 0.3), 5.0)
			c.draw_circle(Vector2(-13, sin(t * 20.0) * 3.0), 2.0, Color(1.0, 0.85, 0.3, 0.7))

		"sword":  # 本命飞剑：剑身 + 剑格 + 剑气弧
			var qi = 0.6 + 0.4 * abs(sin(t * 6.0))
			c.draw_arc(Vector2(-2, 0), 14.0, -PI * 0.5, PI * 0.5, 16,
				Color(col2.r, col2.g, col2.b, 0.25 * qi), 2.5)
			c.draw_line(Vector2(-13, 0), Vector2(14, 0), col, 3.2)
			c.draw_line(Vector2(-6, -5.5), Vector2(-6, 5.5), col2, 2.2)
			c.draw_circle(Vector2(14, 0), 2.6, col2)
			c.draw_line(Vector2(-13, 0), Vector2(-7, 0), Color(col2.r, col2.g, col2.b, 0.9), 1.5)

		"thunder":  # 雷法：锯齿闪电 + 分叉 + 闪光
			var fl = fx.get("flicker", true)
			var bright = 0.7 + 0.3 * (sin(t * 30.0) if fl else 1.0)
			var pts = PackedVector2Array([
				Vector2(-13, 0), Vector2(-4, -7), Vector2(0, 2), Vector2(6, -6), Vector2(13, 3)])
			c.draw_polyline(pts, Color(col.r, col.g, col.b, 0.4 * bright), 5.0)
			c.draw_polyline(pts, col, 3.0)
			c.draw_line(Vector2(0, 2), Vector2(3, 11), Color(col2.r, col2.g, col2.b, 0.8 * bright), 2.0)
			c.draw_line(Vector2(6, -6), Vector2(11, -13), Color(col2.r, col2.g, col2.b, 0.7 * bright), 1.8)
			c.draw_circle(Vector2(13, 3), 3.5, Color(col2.r, col2.g, col2.b, 0.9 * bright))

		"bowshot":  # 穿云箭：弓臂 + 箭羽 + 能量箭头
			var glint = 0.6 + 0.4 * abs(sin(t * 22.0))
			c.draw_line(Vector2(-12, -8), Vector2(2, 0), col, 2.2)
			c.draw_line(Vector2(-12, 8), Vector2(2, 0), col, 2.2)
			c.draw_line(Vector2(-12, -8), Vector2(-12, 8), col2, 1.6)
			c.draw_colored_polygon(PackedVector2Array([
				Vector2(14, 0), Vector2(3, -4), Vector2(6, 0), Vector2(3, 4)]), col2)
			c.draw_line(Vector2(-12, 0), Vector2(6, 0), Color(col2.r, col2.g, col2.b, 0.4 * glint), 1.2)
			c.draw_circle(Vector2(14, 0), 2.0, Color(1.0, 1.0, 0.8, 0.9))

		"element_orb":  # 元素核：三相元素核 + 环绕碎符 + 脉冲
			var pulse = 0.8 + 0.2 * sin(t * 10.0)
			c.draw_circle(Vector2.ZERO, 10.0, Color(col.r, col.g, col.b, 0.3 * pulse))
			c.draw_colored_polygon(PackedVector2Array([
				Vector2(0, -6), Vector2(5.2, 3), Vector2(-5.2, 3)]), col)
			c.draw_circle(Vector2.ZERO, 3.0, col2)
			for k in range(3):
				var a = -t * 5.0 + k * TAU / 3.0
				var p = Vector2(cos(a), sin(a)) * 14.0
				c.draw_rect(Rect2(p - Vector2(1.4, 2.4), Vector2(2.8, 4.8)),
					Color(col2.r, col2.g, col2.b, 0.85))
			c.draw_arc(Vector2.ZERO, 15.0, t * 4.0, t * 4.0 + PI * 1.2, 20,
				Color(col2.r, col2.g, col2.b, 0.35), 1.5)

		"shieldbow":  # 破盾弓：弓臂 + 能量弓弦 + 破盾箭簇 + 微光
			var glint = 0.6 + 0.4 * abs(sin(t * 20.0))
			c.draw_arc(Vector2(-2, 0), 12.0, -PI * 0.5, PI * 0.5, 18, col, 3.0)
			c.draw_arc(Vector2(-2, 0), 12.0, PI * 0.5, PI * 1.5, 18, col, 3.0)
			c.draw_line(Vector2(-2, -12), Vector2(-2, 12), col2, 1.4)
			c.draw_line(Vector2(-2, 0), Vector2(7, 0), Color(col2.r, col2.g, col2.b, 0.4 * glint), 1.2)
			c.draw_colored_polygon(PackedVector2Array([
				Vector2(16, 0), Vector2(5, -4), Vector2(8, 0), Vector2(5, 4)]), col2)
			c.draw_circle(Vector2(16, 0), 2.2, Color(1.0, 1.0, 0.85, 0.95))

		_:
			c.draw_circle(Vector2.ZERO, 6.0, col)
			c.draw_circle(Vector2.ZERO, 3.0, col2)

	# 质变/超质变特效光环（叠加在弹体之上）
	var tier = str(visual.get("tier", ""))
	if tier != "":
		_tier_glow(c, tier, Vector2.ZERO, 14.0, t)

# =====================================================================
# 光环（aura）：以玩家为中心，半径 r
# =====================================================================
static func draw_aura(c: CanvasItem, shape: String, r: float, visual: Dictionary) -> void:
	var col = _c(visual, "color", Color(0.30, 0.85, 0.35))
	var col2 = _c(visual, "color2", col.lightened(0.3))
	var fx = visual.get("fx", {})
	var t = _t()
	var pulse = 1.0 + fx.get("pulse", 0.0) * sin(t * 3.0) * 0.08
	var rr = r * pulse
	# 基础柔光底
	c.draw_circle(Vector2.ZERO, rr, Color(col.r, col.g, col.b, 0.10))
	_glow(c, Vector2.ZERO, rr, col2, fx.get("glow", 0.0))
	_particles(c, fx.get("particles", "none"), rr, col, col2, t)

	match shape:
		"poison":  # 大蒜：翻涌毒云 + 上升气泡
			for i in range(6):
				var a = (i / 6.0) * TAU + t * 0.3
				var wob = sin(t * 2.0 + i) * 0.12
				var rad = rr * (0.5 + 0.35 * wob)
				c.draw_circle(Vector2(cos(a) * rad, sin(a) * rad), rr * 0.22,
					Color(col.r, col.g, col.b, 0.18))
			c.draw_arc(Vector2.ZERO, rr, 0, TAU, 48, Color(col2.r, col2.g, col2.b, 0.4), 2.0)

		"vine":  # 青纹藤：缠绕藤蔓 + 发光尖端摇曳
			for i in range(10):
				var a = t * 0.4 + i * TAU / 10.0
				var tip = Vector2(cos(a), sin(a)) * rr
				var mid = Vector2(cos(a + 0.5), sin(a + 0.5)) * rr * 0.55
				c.draw_polyline(PackedVector2Array([Vector2.ZERO, mid, tip]),
					Color(col2.r, col2.g, col2.b, 0.7), 3.0)
				c.draw_circle(tip, 3.0 + sin(t * 4.0 + i) * 1.0, Color(col2.r, col2.g, col2.b, 0.9))

		"tower":  # 灵光宝塔：七层同心光幕 + 上浮光点
			for i in range(7):
				var rrr = rr * (1.0 - i * 0.13)
				c.draw_arc(Vector2.ZERO, rrr, 0, TAU, 40,
					Color(col.r, col.g, col.b, 0.14 + i * 0.05), 2.0)
			c.draw_circle(Vector2.ZERO, rr * 0.16, Color(col2.r, col2.g, col2.b, 0.85))
			for k in range(5):
				var a = t * 1.2 + k * TAU / 5.0
				var yy = -fmod(t * 14.0 + k * 9.0, rr)
				c.draw_circle(Vector2(cos(a) * rr * 0.8, yy), 2.0, Color(col2.r, col2.g, col2.b, 0.8))

		"landscape":  # 山河社稷图：水墨卷轴 + 漂移墨晕
			c.draw_circle(Vector2.ZERO, rr, Color(col.r, col.g, col.b, 0.09))
			for i in range(5):
				var a0 = t * 0.3 + i * TAU / 5.0
				c.draw_arc(Vector2.ZERO, rr * (0.45 + i * 0.11), a0, a0 + PI * 0.7, 24,
					Color(col2.r, col2.g, col2.b, 0.45), 3.0)
			for k in range(4):
				var a = t * 0.6 + k * TAU / 4.0
				var p = Vector2(cos(a), sin(a)) * rr * 0.6
				c.draw_circle(p, 4.0, Color(col.r, col.g, col.b, 0.18))

		"talisman":  # 符箓大阵：外圈符文环 + 旋转符文 + 脉动
			c.draw_circle(Vector2.ZERO, rr, Color(col.r, col.g, col.b, 0.09))
			c.draw_arc(Vector2.ZERO, rr, 0, TAU, 48, Color(col.r, col.g, col.b, 0.5), 2.0)
			for i in range(8):
				var a = -t * 0.6 + i * TAU / 8.0
				var p = Vector2(cos(a), sin(a)) * rr * 0.82
				c.draw_rect(Rect2(p - Vector2(3, 5), Vector2(6, 10)), Color(col2.r, col2.g, col2.b, 0.85))

		"holy_circle":  # 圣环：十字圣光 + 内旋治疗符 + 上浮光点
			c.draw_circle(Vector2.ZERO, rr, Color(col.r, col.g, col.b, 0.10))
			c.draw_arc(Vector2.ZERO, rr, 0, TAU, 48, Color(col2.r, col2.g, col2.b, 0.5), 2.0)
			c.draw_line(Vector2.ZERO, Vector2(0, -rr * 0.7), Color(col2.r, col2.g, col2.b, 0.7), 2.0)
			c.draw_line(Vector2.ZERO, Vector2(0, rr * 0.7), Color(col2.r, col2.g, col2.b, 0.7), 2.0)
			c.draw_line(Vector2.ZERO, Vector2(-rr * 0.7, 0), Color(col2.r, col2.g, col2.b, 0.7), 2.0)
			c.draw_line(Vector2.ZERO, Vector2(rr * 0.7, 0), Color(col2.r, col2.g, col2.b, 0.7), 2.0)
			c.draw_circle(Vector2.ZERO, rr * 0.18, Color(col2.r, col2.g, col2.b, 0.9))
			for k in range(6):
				var a = t * 1.0 + k * TAU / 6.0
				var yy = -fmod(t * 12.0 + k * 7.0, rr)
				c.draw_circle(Vector2(cos(a) * rr * 0.7, yy), 2.0, Color(col2.r, col2.g, col2.b, 0.8))

		_:
			c.draw_circle(Vector2.ZERO, rr * 0.66, Color(col2.r, col2.g, col2.b, 0.10))
			c.draw_arc(Vector2.ZERO, rr, 0, TAU, 48, Color(col2.r, col2.g, col2.b, 0.45), 2.0)

	# 质变/超质变特效光环（叠加在光环中心）
	var tier = str(visual.get("tier", ""))
	if tier != "":
		_tier_glow(c, tier, Vector2.ZERO, rr, t)

# =====================================================================
# 环绕（orbit）：逐个环绕体在局部坐标 pos 处绘制
# =====================================================================
static func draw_orbit(c: CanvasItem, shape: String, pos: Vector2, visual: Dictionary, ang: float) -> void:
	var col = _c(visual, "color", Color(0.4, 0.8, 1.0))
	var col2 = _c(visual, "color2", Color(0.85, 0.95, 1.0))
	var fx = visual.get("fx", {})
	var t = _t()
	_glow(c, pos, 14.0, col2, fx.get("glow", 0.0))
	var spin = ang + t * fx.get("spin", 0.0)

	match shape:
		"page":  # 圣经：翻页书页 + 圣光十字 + 闪光
			var flip = 0.5 + 0.5 * sin(t * 5.0)
			c.draw_rect(Rect2(pos - Vector2(7, 9), Vector2(14, 18)), Color(col.r, col.g, col.b, 0.9))
			c.draw_rect(Rect2(pos - Vector2(4, 6), Vector2(8 * flip, 12)), Color(col2.r, col2.g, col2.b, 0.95))
			c.draw_line(pos - Vector2(0, 11), pos + Vector2(0, 11), Color(col2.r, col2.g, col2.b, 0.85), 1.5)
			c.draw_line(pos - Vector2(6, 0), pos + Vector2(6, 0), Color(col2.r, col2.g, col2.b, 0.85), 1.5)

		"crescent":  # 鞭子：新月弧刃 + 残影
			c.draw_arc(pos, 17.0, ang, ang + PI * 0.85, 20, Color(col.r, col.g, col.b, 0.35), 7.0)
			c.draw_arc(pos, 17.0, ang, ang + PI * 0.85, 20, Color(col.r, col.g, col.b, 0.95), 4.0)
			c.draw_circle(pos, 4.0, Color(col2.r, col2.g, col2.b, 0.9))

		"hammer":  # 裂地锤：重锤 + 冲击火花
			var dir = Vector2(cos(ang), sin(ang))
			c.draw_line(pos - dir * 10.0, pos + dir * 4.0, Color(0.45, 0.32, 0.20), 4.0)
			var head = pos + dir * 9.0
			c.draw_rect(Rect2(head - Vector2(9, 7), Vector2(18, 14)), Color(col.r, col.g, col.b, 0.95))
			c.draw_rect(Rect2(head - Vector2(9, 7), Vector2(18, 14)), Color(col2.r, col2.g, col2.b, 0.9), false, 2.0)
			for k in range(4):
				var sa = spin * 3.0 + k * TAU / 4.0
				var sp = head + Vector2(cos(sa), sin(sa)) * 12.0
				c.draw_line(head, sp, Color(col2.r, col2.g, col2.b, 0.6), 1.5)

		"beast":  # 月影兔：兔身 + 长耳 + 踢击拖尾
			c.draw_circle(pos, 8.0, Color(col.r, col.g, col.b, 0.95))
			c.draw_circle(pos + Vector2(0, -9), 4.5, Color(col.r, col.g, col.b, 0.95))
			c.draw_line(pos + Vector2(-3, -12), pos + Vector2(-5, -21), Color(col2.r, col2.g, col2.b), 3.0)
			c.draw_line(pos + Vector2(3, -12), pos + Vector2(5, -21), Color(col2.r, col2.g, col2.b), 3.0)
			var kick = Vector2(cos(ang + PI / 2), sin(ang + PI / 2))
			c.draw_line(pos, pos + kick * (10.0 + 4.0 * abs(sin(t * 8.0))), Color(col2.r, col2.g, col2.b, 0.5), 2.5)

		"treasure":  # 法宝环绕：旋转菱形 + 内核 + 星点
			var a = spin * 2.0
			var pts = PackedVector2Array()
			for i in range(4):
				var tt = a + i * TAU / 4.0
				pts.append(pos + Vector2(cos(tt), sin(tt)) * 12.0)
			c.draw_colored_polygon(pts, Color(col.r, col.g, col.b, 0.9))
			c.draw_circle(pos, 4.0, Color(col2.r, col2.g, col2.b, 1.0))
			for k in range(3):
				var sa = spin * 2.0 + k * TAU / 3.0
				c.draw_circle(pos + Vector2(cos(sa), sin(sa)) * 16.0, 1.6, Color(col2.r, col2.g, col2.b, 0.9))

		"sword_array":  # 剑阵：剑影指向切线 + 剑气拖尾
			var dir2 = Vector2(cos(ang + PI / 2), sin(ang + PI / 2))
			var perp = Vector2(-dir2.y, dir2.x)
			c.draw_line(pos - dir2 * 13.0, pos + dir2 * 13.0, Color(col.r, col.g, col.b, 0.95), 3.0)
			c.draw_line(pos - dir2 * 6.0 - perp * 5.0, pos - dir2 * 6.0 + perp * 5.0,
				Color(col2.r, col2.g, col2.b, 0.9), 2.0)
			c.draw_arc(pos - dir2 * 13.0, 6.0, -PI * 0.5, PI * 0.5, 12,
				Color(col2.r, col2.g, col2.b, 0.35), 1.5)
			c.draw_circle(pos + dir2 * 13.0, 2.5, Color(col2.r, col2.g, col2.b, 1.0))

		"greatsword":  # 巨剑：巨型刃弧 + 残影 + 冲击火花
			c.draw_arc(pos, 20.0, ang, ang + PI * 0.9, 22, Color(col.r, col.g, col.b, 0.3), 9.0)
			c.draw_arc(pos, 20.0, ang, ang + PI * 0.9, 22, Color(col.r, col.g, col.b, 0.95), 5.0)
			c.draw_rect(Rect2(pos - Vector2(4, 16), Vector2(8, 32)), Color(col2.r, col2.g, col2.b, 0.9))
			c.draw_circle(pos, 5.0, Color(col2.r, col2.g, col2.b, 1.0))
			for k in range(4):
				var sa = spin * 2.5 + k * TAU / 4.0
				var sp = pos + Vector2(cos(sa), sin(sa)) * 15.0
				c.draw_line(pos, sp, Color(col2.r, col2.g, col2.b, 0.55), 1.5)

		"shield":  # 壁垒盾：圆盾 + 十字铆钉 + 自转微光
			var dir = Vector2(cos(ang), sin(ang))
			c.draw_circle(pos, 13.0, Color(col.r, col.g, col.b, 0.92))
			c.draw_arc(pos, 13.0, 0, TAU, 28, Color(col2.r, col2.g, col2.b, 0.95), 2.5)
			c.draw_circle(pos, 5.0, Color(col2.r, col2.g, col2.b, 0.85))
			c.draw_line(pos - dir * 9.0, pos + dir * 9.0, Color(col2.r, col2.g, col2.b, 0.6), 1.5)
			c.draw_line(pos - Vector2(-dir.y, dir.x) * 9.0, pos + Vector2(-dir.y, dir.x) * 9.0,
				Color(col2.r, col2.g, col2.b, 0.6), 1.5)

		"summon":  # 召唤环：悬浮召唤物 + 飘尾 + 环绕微光
			var wob = sin(t * 6.0 + ang * 3.0) * 2.5
			var body = pos + Vector2(0, wob)
			c.draw_circle(body, 8.0, Color(col.r, col.g, col.b, 0.95))
			c.draw_circle(body, 3.5, Color(col2.r, col2.g, col2.b, 1.0))
			c.draw_line(body, body + Vector2(0, -12.0), Color(col2.r, col2.g, col2.b, 0.4), 1.5)
			c.draw_circle(body + Vector2(0, -12.0), 1.5, Color(col2.r, col2.g, col2.b, 0.7))
			for k in range(3):
				var sa = spin * 2.0 + k * TAU / 3.0
				c.draw_circle(body + Vector2(cos(sa), sin(sa)) * 13.0, 1.4, Color(col2.r, col2.g, col2.b, 0.8))

		_:
			c.draw_circle(pos, 14.0, Color(col.r, col.g, col.b, 0.85))

	# 质变/超质变特效光环（叠加在环绕体上）
	var tier = str(visual.get("tier", ""))
	if tier != "":
		_tier_glow(c, tier, pos, 16.0, t)

# =====================================================================
# 横扫（sweep）：以玩家为中心旋转的刀光线段（直径），命中线段上的敌人。
# 由 weapon_base._rotate_sweep 调用：dir 为当前刀光方向（单位向量），R 为半径。
# =====================================================================
static func draw_sweep(c: CanvasItem, shape: String, dir: Vector2, R: float, visual: Dictionary) -> void:
	var col = _c(visual, "color", Color(0.9, 0.5, 0.2))
	var col2 = _c(visual, "color2", Color(1.0, 0.85, 0.5))
	var fx = visual.get("fx", {})
	var t = _t()
	_glow(c, Vector2.ZERO, 18.0, col2, fx.get("glow", 0.35))
	var tip = dir * R
	var tail = -dir * R
	var perp = Vector2(-dir.y, dir.x)
	# 刀光线段（多层叠加：外晕 → 主刃 → 高光芯）
	c.draw_line(tail, tip, Color(col.r, col.g, col.b, 0.30), 18.0)
	c.draw_line(tail, tip, Color(col.r, col.g, col.b, 0.9), 10.0)
	c.draw_line(tail, tip, Color(col2.r, col2.g, col2.b, 0.95), 4.0)
	# 刃尖高光 + 拖尾火花
	c.draw_circle(tip, 7.0, col2)
	c.draw_circle(tip, 3.0, Color(1.0, 1.0, 1.0, 0.9))
	for k in range(3):
		var sa = t * 6.0 + k * TAU / 3.0
		var sp = tip + Vector2(cos(sa), sin(sa)) * 10.0
		c.draw_line(tip, sp, Color(col2.r, col2.g, col2.b, 0.55), 1.5)
	# 巨剑专属：矩形巨刃（更厚重）
	if shape == "greatsword":
		var blade = PackedVector2Array([
			tail - perp * 11.0, tip - perp * 11.0, tip + perp * 11.0, tail + perp * 11.0
		])
		c.draw_colored_polygon(blade, Color(col.r, col.g, col.b, 0.45))
		c.draw_line(tail, tip, Color(col2.r, col2.g, col2.b, 0.9), 3.0)
	# 鞭子专属：沿刀光点缀残影节点
	elif shape == "crescent":
		for k in range(4):
			var p = tail.lerp(tip, float(k + 1) / 5.0)
			c.draw_circle(p, 3.0, Color(col2.r, col2.g, col2.b, 0.5))
	# 锤专属：刃端重锤头
	elif shape == "hammer":
		c.draw_rect(Rect2(tip - perp * 12.0 - dir * 8.0, Vector2(24.0, 24.0)), Color(col.r, col.g, col.b, 0.85))
		c.draw_rect(Rect2(tip - perp * 12.0 - dir * 8.0, Vector2(24.0, 24.0)), Color(col2.r, col2.g, col2.b, 0.9), false, 2.0)

	# 质变/超质变特效光环（叠加在横扫中心）
	var tier = str(visual.get("tier", ""))
	if tier != "":
		_tier_glow(c, tier, Vector2.ZERO, R * 0.5, t)
