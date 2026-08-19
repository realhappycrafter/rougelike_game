extends RefCounted
## CreatureVisual —— 怪物与玩家的「模型」集中渲染器（参照 WeaponVisual / AffixVisual 模式）
## 所有造型均以程序化像素基元一次性光栅化到 96×96 贴图并缓存，之后由
## EnemyManager（敌人）与 Player（玩家）通过 draw_texture_rect 合批绘制。
## 这样新增一种怪物 shape 或职业立绘，只需在这里加一个 _shape_* / _player_* 分支，
## 不污染敌人管理 / 玩家逻辑，也不引入外部美术资源（对 Web 导出零负担）。
##
## 动态模型（2026-08-19）：
##   - get_enemy_texture(shape,col,world,frame)：frame ∈ {0,1,2}
##       0=走路A基准，1=走路B（下沉2px），2=攻击（上抬2px + 红眼凶光）
##   - get_player_texture(class_id,frame)：frame ∈ {0,1} 双脚步态交替
##
## 画风精修（2026-08-19）：主体改用多边形（梯形/刃形/尖角），弱化圆形感；
## 每只怪/每个职业都有明确四肢、明暗层次与专属特征，像素画风更清晰细致。
## 世界风格：外描边色（rim）+ 灵光色（glow）按世界区分，一眼可辨三界归属。

const SZ: int = 96                 # 贴图分辨率
const C: float = 48.0              # 画布中心

const CLASS_COLORS: Dictionary = {
	"warrior":      Color(0.55, 0.62, 0.80),  # 钢铁蓝
	"archer":       Color(0.45, 0.74, 0.42),  # 游侠绿
	"guardian":     Color(0.82, 0.66, 0.34),  # 古铜金
	"element_mage": Color(0.66, 0.50, 0.88),  # 元素紫
	"summoner":     Color(0.38, 0.76, 0.74),  # 召唤青
	"healer":       Color(0.94, 0.86, 0.92),  # 圣光白
	"":             Color(0.52, 0.52, 0.58),  # 默认冒险者灰
}
const SKIN: Color = Color(0.90, 0.74, 0.58)
const SKIN_D: Color = Color(0.62, 0.46, 0.34)
const EYE_W: Color = Color(0.96, 0.93, 0.82, 1.0)
const PUPIL: Color = Color(0.10, 0.07, 0.12, 1.0)

const WORLD_STYLE: Dictionary = {
	"zombie":  { "rim": Color(0.09, 0.15, 0.10), "glow": Color(0.55, 0.85, 0.35) },
	"douluo":  { "rim": Color(0.05, 0.14, 0.17), "glow": Color(0.20, 0.95, 0.85) },
	"xiuxian": { "rim": Color(0.18, 0.12, 0.05), "glow": Color(1.00, 0.82, 0.30) },
}

const EYE_POS: Dictionary = {
	"imp":     [42, 34, 54, 34],
	"fast":    [48, 40],
	"brute":   [42, 30, 54, 30],
	"wraith":  [42, 32, 54, 32],
	"swift":   [48, 48],
	"elite":   [42, 50, 54, 50],
	"stone":   [48, 50],
	"corrode": [42, 48, 54, 48],
	"boss":    [38, 52, 58, 52],
}

static func _style(world: String) -> Dictionary:
	return WORLD_STYLE.get(world, WORLD_STYLE["zombie"])

static var _enemy_cache = null
static var _player_cache = null

# ---------------------------------------------------------------------------
# 对外接口
# ---------------------------------------------------------------------------
static func get_enemy_texture(shape: String, col: Color, world: String = "", frame: int = 0) -> Texture2D:
	if _enemy_cache == null:
		_enemy_cache = {}
	var st = _style(world)
	var key = world + "|" + shape + "|" + col.to_html() + "|f" + str(frame)
	if _enemy_cache.has(key):
		return _enemy_cache[key]
	var img = Image.create(SZ, SZ, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	match shape:
		"imp":     _shape_imp(img, col, st)
		"fast":    _shape_fast(img, col, st)
		"brute":   _shape_brute(img, col, st)
		"wraith":  _shape_wraith(img, col, st)
		"swift":   _shape_swift(img, col, st)
		"elite":   _shape_elite(img, col, st)
		"stone":   _shape_stone(img, col, st)
		"corrode": _shape_corrode(img, col, st)
		"boss":    _shape_boss(img, col, st, world)
		_:         _shape_imp(img, col, st)
	if shape != "boss":
		_world_accent(img, world, col, st)
	_apply_enemy_frame(img, frame, shape)
	var tex = ImageTexture.create_from_image(img)
	_enemy_cache[key] = tex
	return tex

static func _apply_enemy_frame(img: Image, frame: int, shape: String) -> void:
	if frame <= 0:
		return
	var shifted = Image.create(SZ, SZ, false, Image.FORMAT_RGBA8)
	shifted.fill(Color(0, 0, 0, 0))
	if frame == 1:
		shifted.blit_rect(img, Rect2(0, 0, SZ, SZ - 2), Vector2(0, 2))
	elif frame == 2:
		shifted.blit_rect(img, Rect2(0, 2, SZ, SZ - 2), Vector2(0, 0))
	img.blit_rect(shifted, Rect2(0, 0, SZ, SZ), Vector2.ZERO)
	if frame == 2:
		_attack_eyes(img, shape)

static func _attack_eyes(img: Image, shape: String) -> void:
	var pos = EYE_POS.get(shape, [40, 52, 56, 52])
	var pairs = [[pos[0], pos[1]]]
	if pos.size() >= 4:
		pairs.append([pos[2], pos[3]])
	for pr in pairs:
		var ex = float(pr[0]); var ey = float(pr[1])
		_fill_circle(img, ex, ey, 7.0, Color(1.0, 0.15, 0.05, 0.75))
		_fill_circle(img, ex, ey, 4.5, Color(1.0, 0.35, 0.10, 0.95))
		_fill_circle(img, ex, ey, 2.0, Color(1.0, 0.95, 0.7, 1.0))

static func get_player_texture(class_id: String, frame: int = 0) -> Texture2D:
	if _player_cache == null:
		_player_cache = {}
	var key = str(class_id) + "|f" + str(frame)
	if _player_cache.has(key):
		return _player_cache[key]
	var col = CLASS_COLORS.get(class_id, CLASS_COLORS[""])
	var img = Image.create(SZ, SZ, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	match class_id:
		"warrior":      _player_warrior(img, col, frame)
		"archer":       _player_archer(img, col, frame)
		"guardian":     _player_guardian(img, col, frame)
		"element_mage": _player_mage(img, col, frame)
		"summoner":     _player_summoner(img, col, frame)
		"healer":       _player_healer(img, col, frame)
		_:              _player_default(img, col, frame)
	var tex = ImageTexture.create_from_image(img)
	_player_cache[key] = tex
	return tex

# ---------------------------------------------------------------------------
# 像素基元（手写光栅化）
# ---------------------------------------------------------------------------
static func _set_px(img: Image, x: int, y: int, col: Color) -> void:
	if x >= 0 and x < img.get_width() and y >= 0 and y < img.get_height():
		img.set_pixel(x, y, col)

static func _fill_circle(img: Image, cx: float, cy: float, r: float, col: Color) -> void:
	var r2 = r * r
	for y in range(int(cy - r - 1), int(cy + r + 1) + 1):
		for x in range(int(cx - r - 1), int(cx + r + 1) + 1):
			var dx = x - cx; var dy = y - cy
			if dx * dx + dy * dy <= r2:
				_set_px(img, x, y, col)

static func _fill_ellipse(img: Image, cx: float, cy: float, rx: float, ry: float, col: Color) -> void:
	for y in range(int(cy - ry - 1), int(cy + ry + 1) + 1):
		for x in range(int(cx - rx - 1), int(cx + rx + 1) + 1):
			var dx = (x - cx) / rx; var dy = (y - cy) / ry
			if dx * dx + dy * dy <= 1.0:
				_set_px(img, x, y, col)

static func _fill_roundrect(img: Image, x: float, y: float, w: float, h: float, rad: float, col: Color) -> void:
	for yy in range(int(y), int(y + h) + 1):
		for xx in range(int(x), int(x + w) + 1):
			var nx = min(max(float(xx), x + rad), x + w - rad)
			var ny = min(max(float(yy), y + rad), y + h - rad)
			var dx = xx - nx; var dy = yy - ny
			if dx * dx + dy * dy <= rad * rad:
				_set_px(img, xx, yy, col)

static func _fill_tri(img: Image, p0: Vector2, p1: Vector2, p2: Vector2, col: Color) -> void:
	var minx = int(min(p0.x, p1.x, p2.x)); var maxx = int(max(p0.x, p1.x, p2.x))
	var miny = int(min(p0.y, p1.y, p2.y)); var maxy = int(max(p0.y, p1.y, p2.y))
	for y in range(miny, maxy + 1):
		for x in range(minx, maxx + 1):
			var w0 = (x - p1.x) * (p2.y - p1.y) - (p2.x - p1.x) * (y - p1.y)
			var w1 = (x - p2.x) * (p0.y - p2.y) - (p0.x - p2.x) * (y - p2.y)
			var w2 = (x - p0.x) * (p1.y - p0.y) - (p1.x - p0.x) * (y - p0.y)
			if (w0 >= 0 and w1 >= 0 and w2 >= 0) or (w0 <= 0 and w1 <= 0 and w2 <= 0):
				_set_px(img, x, y, col)

static func _fill_poly(img: Image, pts: PackedVector2Array, col: Color) -> void:
	var minx = 9999.0; var maxx = -9999.0; var miny = 9999.0; var maxy = -9999.0
	for p in pts:
		minx = min(minx, p.x); maxx = max(maxx, p.x)
		miny = min(miny, p.y); maxy = max(maxy, p.y)
	for y in range(int(miny), int(maxy) + 1):
		for x in range(int(minx), int(maxx) + 1):
			if _point_in_poly(float(x), float(y), pts):
				_set_px(img, x, y, col)

static func _point_in_poly(x: float, y: float, pts: PackedVector2Array) -> bool:
	var inside = false
	var n = pts.size()
	var j = n - 1
	for i in range(n):
		var pi = pts[i]; var pj = pts[j]
		if (pi.y > y) != (pj.y > y):
			var denom = pj.y - pi.y
			if denom != 0.0 and x < (pj.x - pi.x) * (y - pi.y) / denom + pi.x:
				inside = not inside
		j = i
	return inside

static func _o_circle(img, cx, cy, r, col, dark):
	_fill_circle(img, cx, cy, r + 2.5, dark)
	_fill_circle(img, cx, cy, r, col)

static func _o_ellipse(img, cx, cy, rx, ry, col, dark):
	_fill_ellipse(img, cx, cy, rx + 2.5, ry + 2.5, dark)
	_fill_ellipse(img, cx, cy, rx, ry, col)

static func _o_roundrect(img, x, y, w, h, rad, col, dark):
	_fill_roundrect(img, x - 2.0, y - 2.0, w + 4.0, h + 4.0, rad + 2.0, dark)
	_fill_roundrect(img, x, y, w, h, rad, col)

static func _o_tri(img, p0: Vector2, p1: Vector2, p2: Vector2, col, dark):
	var ctr = (p0 + p1 + p2) / 3.0
	_fill_tri(img, _infl(p0, ctr, 2.5), _infl(p1, ctr, 2.5), _infl(p2, ctr, 2.5), dark)
	_fill_tri(img, p0, p1, p2, col)

static func _o_poly(img, pts: PackedVector2Array, col, dark):
	var ctr = Vector2.ZERO
	for p in pts:
		ctr += p
	ctr /= float(pts.size())
	var dp: PackedVector2Array = []
	for p in pts:
		dp.append(_infl(p, ctr, 2.5))
	_fill_poly(img, dp, dark)
	_fill_poly(img, pts, col)

static func _infl(p: Vector2, c: Vector2, d: float) -> Vector2:
	var v = p - c
	if v.length_squared() < 0.0001:
		return p
	return p + v.normalized() * d

static func _eyes(img, x1, y1, x2, y2, r = 4.0):
	_o_circle(img, x1, y1, r, EYE_W, Color(0.05, 0.04, 0.06))
	_fill_circle(img, x1, y1, r * 0.5, PUPIL)
	_o_circle(img, x2, y2, r, EYE_W, Color(0.05, 0.04, 0.06))
	_fill_circle(img, x2, y2, r * 0.5, PUPIL)

static func _player_feet(img, frame: int, col) -> void:
	var d = col.darkened(0.55)
	if frame == 1:
		_fill_roundrect(img, 37, 82, 9, 9, 3, d)
		_fill_roundrect(img, 52, 84, 9, 9, 3, d)
	else:
		_fill_roundrect(img, 37, 84, 9, 9, 3, d)
		_fill_roundrect(img, 52, 82, 9, 9, 3, d)

static func _world_accent(img, world, col, st) -> void:
	match world:
		"douluo":
			_fill_circle(img, C, 8, 4, Color(st.glow.r, st.glow.g, st.glow.b, 0.85))
			_fill_circle(img, C, 7, 2, Color(1.0, 1.0, 0.9, 0.95))
		"xiuxian":
			for a in range(-120, -59, 12):
				var rad = deg_to_rad(float(a))
				_set_px(img, int(C + cos(rad) * 20.0), int(22.0 + sin(rad) * 20.0), st.glow)
			_set_px(img, int(C + cos(deg_to_rad(-90.0)) * 20.0), int(22.0 + sin(deg_to_rad(-90.0)) * 20.0), Color(1.0, 0.95, 0.7))
		_:
			_set_px(img, 40, 84, Color(0.45, 0.04, 0.04))
			_set_px(img, 41, 85, Color(0.45, 0.04, 0.04))
			_set_px(img, 56, 86, Color(0.45, 0.04, 0.04))
			_set_px(img, 57, 87, Color(0.45, 0.04, 0.04))

# ---------------------------------------------------------------------------
# 怪物造型（精修版：多边形剪影 + 四肢 + 明暗层次，弱化圆形感）
# ---------------------------------------------------------------------------
static func _shape_imp(img, col, st):
	var d = st.rim; var l = col.lightened(0.32); var x = col.darkened(0.22)
	# 弯角（尖三角）
	_o_tri(img, Vector2(36,30), Vector2(45,32), Vector2(24,6), x, d)
	_o_tri(img, Vector2(60,30), Vector2(51,32), Vector2(72,6), x, d)
	# 头（五边形尖下巴）
	_o_poly(img, PackedVector2Array([Vector2(37,24), Vector2(59,24), Vector2(63,33), Vector2(53,43), Vector2(43,43)]), col, d)
	# 身体（倒梯形）
	_o_poly(img, PackedVector2Array([Vector2(29,41), Vector2(67,41), Vector2(58,66), Vector2(38,66)]), col, d)
	# 肚皮高光
	_fill_poly(img, PackedVector2Array([Vector2(39,49), Vector2(57,49), Vector2(53,62), Vector2(43,62)]), l)
	# 双臂
	_o_roundrect(img, 21, 43, 7, 15, 3, col, d)
	_o_roundrect(img, 68, 45, 7, 13, 3, col, d)
	_fill_tri(img, Vector2(22,57), Vector2(27,57), Vector2(24,65), EYE_W)  # 利爪
	# 双腿 + 大脚
	_o_roundrect(img, 36, 64, 8, 11, 3, col, d)
	_o_roundrect(img, 52, 64, 8, 11, 3, col, d)
	_fill_roundrect(img, 31, 72, 13, 5, 2, x)
	_fill_roundrect(img, 52, 72, 13, 5, 2, x)
	# 怒眼 + 獠牙
	_eyes(img, 42, 34, 54, 34, 3.5)
	_fill_tri(img, Vector2(43,43), Vector2(49,43), Vector2(46,50), EYE_W)
	_fill_tri(img, Vector2(51,43), Vector2(57,43), Vector2(54,50), EYE_W)

static func _shape_fast(img, col, st):
	var d = st.rim; var l = col.lightened(0.30); var x = col.darkened(0.20)
	# 流线身躯（长菱形：尖头 + 收尾）
	_o_poly(img, PackedVector2Array([Vector2(C,18), Vector2(68,44), Vector2(C,74), Vector2(28,44)]), col, d)
	# 头锥（更尖的吻部）
	_o_tri(img, Vector2(C,14), Vector2(38,30), Vector2(58,30), col, d)
	# 尾鳍（三叉）
	_o_tri(img, Vector2(C,74), Vector2(36,90), Vector2(44,82), col, d)
	_o_tri(img, Vector2(C,74), Vector2(60,90), Vector2(52,82), col, d)
	_o_tri(img, Vector2(C,80), Vector2(44,92), Vector2(52,92), col, d)
	# 四足（短腿）
	_o_roundrect(img, 32, 70, 6, 11, 2, col, d)
	_o_roundrect(img, 58, 70, 6, 11, 2, col, d)
	# 背刺
	for i in range(3):
		var sx = 36 + i * 13
		_fill_tri(img, Vector2(sx, 32), Vector2(sx + 8, 32), Vector2(sx + 4, 24), x)
	# 眼带 + 尖牙
	_fill_ellipse(img, C, 40, 10, 3, l)
	_fill_circle(img, C, 40, 3, EYE_W)
	_fill_circle(img, C - 4, 42, 1.6, PUPIL)
	_fill_tri(img, Vector2(C - 3, 46), Vector2(C + 3, 46), Vector2(C, 52), EYE_W)

static func _shape_brute(img, col, st):
	var d = st.rim; var l = col.lightened(0.28); var x = col.darkened(0.24)
	# 魁梧躯干（宽肩梯形）
	_o_poly(img, PackedVector2Array([Vector2(17,30), Vector2(79,30), Vector2(70,66), Vector2(26,66)]), col, d)
	# 胸甲高光
	_fill_poly(img, PackedVector2Array([Vector2(27,36), Vector2(69,36), Vector2(62,52), Vector2(34,52)]), l)
	# 头（方颌）
	_o_poly(img, PackedVector2Array([Vector2(35,12), Vector2(61,12), Vector2(65,26), Vector2(50,34), Vector2(31,26)]), col, d)
	# 眉骨 + 眼
	_fill_roundrect(img, 36, 22, 24, 6, 3, d)
	_fill_circle(img, 42, 28, 3, PUPIL)
	_fill_circle(img, 54, 28, 3, PUPIL)
	# 下颚獠牙
	_fill_tri(img, Vector2(38,34), Vector2(44,34), Vector2(41,42), EYE_W)
	_fill_tri(img, Vector2(52,34), Vector2(58,34), Vector2(55,42), EYE_W)
	# 右手狼牙棒（带钉）
	_o_roundrect(img, 72, 40, 10, 28, 4, col, d)
	_o_circle(img, 77, 36, 13, x, d)
	_o_circle(img, 77, 36, 8, col, d)
	for i in range(4):
		var sa = float(i) / 4.0 * TAU
		_fill_tri(img, Vector2(77,36), Vector2(77 + cos(sa + 0.3) * 12, 36 + sin(sa + 0.3) * 12), Vector2(77 + cos(sa - 0.3) * 12, 36 + sin(sa - 0.3) * 12), EYE_W)
	# 左臂
	_o_roundrect(img, 14, 42, 8, 20, 3, col, d)
	# 粗腿
	_o_roundrect(img, 30, 64, 13, 14, 4, col, d)
	_o_roundrect(img, 53, 64, 13, 14, 4, col, d)
	_fill_roundrect(img, 27, 76, 17, 6, 2, x)
	_fill_roundrect(img, 52, 76, 17, 6, 2, x)

static func _shape_wraith(img, col, st):
	var d = st.rim; var l = col.lightened(0.25)
	# 尖兜帽（三角）
	_o_poly(img, PackedVector2Array([Vector2(C,10), Vector2(32,32), Vector2(64,32)]), col, d)
	# 帽檐
	_fill_roundrect(img, 28, 30, 40, 6, 3, col.darkened(0.2))
	# 下垂袍身（梯形 + 破布尖下摆）
	_o_poly(img, PackedVector2Array([Vector2(28,38), Vector2(68,38), Vector2(60,80), Vector2(36,80)]), col, d)
	_o_tri(img, Vector2(34,80), Vector2(43,80), Vector2(37,93), col, d)
	_o_tri(img, Vector2(44,80), Vector2(53,80), Vector2(48,94), col, d)
	_o_tri(img, Vector2(54,80), Vector2(63,80), Vector2(58,92), col, d)
	# 袍身高光折
	_fill_tri(img, Vector2(34,44), Vector2(50,44), Vector2(42,70), l)
	# 空洞眼（暗 + 亮芯）
	_fill_ellipse(img, 42, 36, 5, 7, d)
	_fill_ellipse(img, 54, 36, 5, 7, d)
	_fill_circle(img, 42, 36, 2, l)
	_fill_circle(img, 54, 36, 2, l)
	# 骨手（从袍中伸出）
	_fill_roundrect(img, 20, 50, 8, 5, 2, EYE_W)
	_fill_roundrect(img, 68, 52, 8, 5, 2, EYE_W)

static func _shape_swift(img, col, st):
	var d = st.rim; var l = col.lightened(0.35); var x = col.darkened(0.18)
	# 主刃（狭长箭头）
	_o_poly(img, PackedVector2Array([Vector2(C,8), Vector2(70,44), Vector2(C,86), Vector2(26,44)]), col, d)
	# 刃芯
	_fill_poly(img, PackedVector2Array([Vector2(C,18), Vector2(58,44), Vector2(C,74), Vector2(34,44)]), l)
	# 双翼刃（左右侧张）
	_o_tri(img, Vector2(26,44), Vector2(14,24), Vector2(30,32), col, d)
	_o_tri(img, Vector2(70,44), Vector2(82,24), Vector2(66,32), col, d)
	# 速度纹
	_fill_ellipse(img, C, 44, 3, 24, x)
	# 独眼（发光）
	_fill_circle(img, C, 42, 4, EYE_W)
	_fill_circle(img, C, 42, 2, PUPIL)

static func _shape_elite(img, col, st):
	var d = st.rim; var l = col.lightened(0.32); var x = col.darkened(0.22)
	# 尖刺冠（五根）
	for i in range(5):
		var a = -PI / 2.0 + (i - 2) * 0.5
		var bx = C + cos(a) * 16.0; var by = 34 + sin(a) * 16.0
		_o_tri(img, Vector2(bx - 4, by), Vector2(bx + 4, by), Vector2(bx, by - 16), x, d)
	# 身体（六角战甲）
	var pts = PackedVector2Array()
	for i in range(6):
		var a = float(i) / 6.0 * TAU - PI / 2.0
		pts.append(Vector2(C + cos(a) * 20, 52 + sin(a) * 20))
	_o_poly(img, pts, col, d)
	# 肩刺
	_o_tri(img, Vector2(30,44), Vector2(20,36), Vector2(30,32), col, d)
	_o_tri(img, Vector2(66,44), Vector2(76,36), Vector2(66,32), col, d)
	# 胸芯 + 发光眼
	_fill_poly(img, PackedVector2Array([Vector2(40,46), Vector2(56,46), Vector2(52,58), Vector2(44,58)]), l)
	_eyes(img, 42, 50, 54, 50, 4.5)
	_fill_circle(img, 42, 50, 2.2, st.glow)
	_fill_circle(img, 54, 50, 2.2, st.glow)

static func _shape_stone(img, col, st):
	var d = st.rim; var l = col.lightened(0.30); var x = col.darkened(0.25)
	# 不规则岩体（八边形，棱角分明）
	var pts = PackedVector2Array([
		Vector2(30,32), Vector2(44,24), Vector2(60,28), Vector2(70,42),
		Vector2(66,58), Vector2(52,70), Vector2(34,66), Vector2(24,50)])
	_o_poly(img, pts, col, d)
	# 晶面高光（两处三角）
	_fill_tri(img, Vector2(32,36), Vector2(48,30), Vector2(40,48), l)
	_fill_tri(img, Vector2(56,42), Vector2(66,50), Vector2(52,58), l)
	# 裂纹
	_fill_line(img, Vector2(44,52), Vector2(54,44), x, 2)
	_fill_line(img, Vector2(54,44), Vector2(58,50), x, 2)
	# 独眼（发光）
	_o_circle(img, C, 52, 6, EYE_W, Color(0.05,0.04,0.06))
	_fill_circle(img, C, 52, 3, Color(1.0, 0.4, 0.2))

static func _shape_corrode(img, col, st):
	var d = st.rim; var l = col.lightened(0.24); var x = col.darkened(0.26)
	# 不规则腐蚀体（多个圆叠出凹凸轮廓）
	_o_circle(img, C, 46, 18, col, d)
	_o_circle(img, 36, 58, 10, col, d)
	_o_circle(img, 60, 56, 11, col, d)
	_o_circle(img, 44, 62, 9, col, d)
	# 滴液
	_o_circle(img, C - 16, 76, 5, col, d)
	_o_circle(img, C + 14, 80, 4, col, d)
	_fill_tri(img, Vector2(C - 20, 78), Vector2(C - 12, 78), Vector2(C - 16, 90), col)
	# 酸蚀斑
	_fill_circle(img, 40, 42, 4, l)
	_fill_circle(img, 56, 52, 3, x)
	# 病态眼
	_fill_circle(img, 42, 48, 5, l)
	_fill_circle(img, 54, 48, 5, l)
	_fill_circle(img, 42, 48, 2.4, PUPIL)
	_fill_circle(img, 54, 48, 2.4, PUPIL)

static func _shape_boss(img, col, st, world: String):
	var d = st.rim; var l = col.lightened(0.30); var x = col.darkened(0.24)
	# 巨弯角（双）
	_o_tri(img, Vector2(28,40), Vector2(42,38), Vector2(14,2), x, d)
	_o_tri(img, Vector2(68,40), Vector2(54,38), Vector2(82,2), x, d)
	# 王冠尖
	_o_tri(img, Vector2(38,20), Vector2(46,20), Vector2(42,6), l, d)
	_o_tri(img, Vector2(50,20), Vector2(58,20), Vector2(54,6), l, d)
	# 翼刃（两侧）
	_o_tri(img, Vector2(22,44), Vector2(34,50), Vector2(8,66), x, d)
	_o_tri(img, Vector2(74,44), Vector2(62,50), Vector2(88,66), x, d)
	# 身躯（宽肩倒梯形 + 胸甲）
	_o_poly(img, PackedVector2Array([Vector2(24,42), Vector2(72,42), Vector2(64,82), Vector2(32,82)]), col, d)
	_fill_poly(img, PackedVector2Array([Vector2(34,50), Vector2(62,50), Vector2(56,70), Vector2(40,70)]), l)
	# 爪臂
	_o_roundrect(img, 16, 52, 8, 22, 3, col, d)
	_o_roundrect(img, 72, 52, 8, 22, 3, col, d)
	_fill_tri(img, Vector2(16,74), Vector2(22,74), Vector2(19,84), EYE_W)
	_fill_tri(img, Vector2(74,74), Vector2(80,74), Vector2(77,84), EYE_W)
	# 腿
	_o_roundrect(img, 34, 80, 12, 10, 4, col, d)
	_o_roundrect(img, 50, 80, 12, 10, 4, col, d)
	# 眼（默认血红，按世界覆盖）
	_o_circle(img, 38, 52, 7, EYE_W, Color(0.05,0.04,0.06))
	_fill_circle(img, 38, 52, 4, Color(0.95, 0.12, 0.12))
	_o_circle(img, 58, 52, 7, EYE_W, Color(0.05,0.04,0.06))
	_fill_circle(img, 58, 52, 4, Color(0.95, 0.12, 0.12))
	# 獠牙嘴
	_fill_tri(img, Vector2(40,70), Vector2(48,70), Vector2(44,79), EYE_W)
	_fill_tri(img, Vector2(48,70), Vector2(56,70), Vector2(52,79), EYE_W)
	match world:
		"douluo":
			for a in range(0, 360, 10):
				var rad = deg_to_rad(float(a))
				_set_px(img, int(C + cos(rad) * 36.0), int(62.0 + sin(rad) * 36.0), Color(st.glow.r, st.glow.g, st.glow.b, 0.5))
			_fill_circle(img, 38, 52, 4, st.glow)
			_fill_circle(img, 58, 52, 4, st.glow)
		"xiuxian":
			for a in range(-140, -39, 8):
				var rad = deg_to_rad(float(a))
				_set_px(img, int(C + cos(rad) * 40.0), int(60.0 + sin(rad) * 40.0), st.glow)
			_fill_circle(img, 38, 52, 4, st.glow)
			_fill_circle(img, 58, 52, 4, st.glow)
		_:
			_set_px(img, 40, 72, Color(0.5, 0.05, 0.05))
			_set_px(img, 41, 73, Color(0.5, 0.05, 0.05))
			_set_px(img, 56, 74, Color(0.5, 0.05, 0.05))
			_set_px(img, 57, 75, Color(0.5, 0.05, 0.05))

# 线段（裂纹/装饰用）
static func _fill_line(img, a: Vector2, b: Vector2, col: Color, w: int) -> void:
	var steps = int(a.distance_to(b)) + 1
	for i in range(steps):
		var p = a.lerp(b, float(i) / float(max(1, steps)))
		for k in range(w):
			_set_px(img, int(p.x), int(p.y + k), col)

# ---------------------------------------------------------------------------
# 玩家职业立绘（精修版：更细致的人形 + 装备细节）
# ---------------------------------------------------------------------------
static func _player_legs(img, col) -> void:
	var d = col.darkened(0.5)
	_fill_roundrect(img, 38, 78, 9, 9, 3, d)
	_fill_roundrect(img, 49, 78, 9, 9, 3, d)

static func _player_default(img, col, frame: int):
	var d = col.darkened(0.58); var x = col.darkened(0.30)
	# 兜帽 + 头
	_o_poly(img, PackedVector2Array([Vector2(33,16), Vector2(63,16), Vector2(65,34), Vector2(31,34)]), col, d)
	_fill_circle(img, C, 36, 8, SKIN)
	# 围巾
	_fill_roundrect(img, 33, 40, 30, 7, 3, Color(0.75, 0.30, 0.25))
	# 冒险者短袍
	_o_poly(img, PackedVector2Array([Vector2(33,46), Vector2(63,46), Vector2(67,80), Vector2(29,80)]), col, d)
	_fill_poly(img, PackedVector2Array([Vector2(36,52), Vector2(60,52), Vector2(56,74), Vector2(40,74)]), x)
	# 腰带
	_fill_roundrect(img, 32, 66, 32, 6, 2, Color(0.35, 0.28, 0.20))
	# 挂剑
	_o_roundrect(img, 66, 50, 5, 28, 2, Color(0.85, 0.85, 0.9), Color(0.2, 0.2, 0.25))
	# 眼
	_fill_roundrect(img, 41, 34, 6, 3, 1, d)
	_fill_roundrect(img, 49, 34, 6, 3, 1, d)
	_player_feet(img, frame, col)

static func _player_warrior(img, col, frame: int):
	var d = col.darkened(0.55); var x = col.darkened(0.25)
	# 头盔（带盔沿 + 顶缨）
	_o_poly(img, PackedVector2Array([Vector2(35,16), Vector2(61,16), Vector2(63,32), Vector2(33,32)]), col, d)
	_fill_roundrect(img, 42, 6, 12, 6, 3, Color(0.9, 0.25, 0.2))   # 红缨
	_fill_roundrect(img, 36, 28, 24, 5, 2, d)                      # 面甲缝
	# 重甲躯干
	_o_poly(img, PackedVector2Array([Vector2(31,40), Vector2(65,40), Vector2(69,78), Vector2(27,78)]), col, d)
	# 胸甲板 + 铆钉
	_fill_poly(img, PackedVector2Array([Vector2(35,46), Vector2(61,46), Vector2(57,62), Vector2(39,62)]), x)
	_fill_circle(img, C, 52, 2.2, Color(0.95, 0.85, 0.5))
	_fill_circle(img, 42, 52, 1.6, Color(0.95, 0.85, 0.5))
	_fill_circle(img, 54, 52, 1.6, Color(0.95, 0.85, 0.5))
	# 肩甲
	_o_circle(img, 31, 44, 8, x, d)
	_o_circle(img, 65, 44, 8, x, d)
	# 背后巨剑（斜背）
	_o_roundrect(img, 64, 20, 7, 48, 3, Color(0.82, 0.84, 0.9), Color(0.22, 0.24, 0.3))
	_fill_roundrect(img, 61, 34, 13, 5, 2, Color(0.85, 0.68, 0.30))
	# 眼
	_fill_circle(img, 43, 30, 2.2, SKIN)
	_fill_circle(img, 53, 30, 2.2, SKIN)
	_fill_circle(img, 43, 30, 1.0, PUPIL)
	_fill_circle(img, 53, 30, 1.0, PUPIL)
	_player_feet(img, frame, col)

static func _player_archer(img, col, frame: int):
	var d = col.darkened(0.55); var x = col.darkened(0.25)
	# 尖顶兜帽
	_o_poly(img, PackedVector2Array([Vector2(C,6), Vector2(33,30), Vector2(63,30)]), col, d)
	_fill_circle(img, C, 36, 8, SKIN)
	# 轻甲衣
	_o_poly(img, PackedVector2Array([Vector2(33,44), Vector2(63,44), Vector2(66,78), Vector2(30,78)]), col, d)
	_fill_poly(img, PackedVector2Array([Vector2(36,50), Vector2(60,50), Vector2(57,72), Vector2(39,72)]), x)
	# 弓（弯杆 + 弦）
	_o_roundrect(img, 72, 18, 5, 46, 2, Color(0.55, 0.38, 0.22), Color(0.2, 0.12, 0.06))
	_fill_roundrect(img, 69, 20, 2, 42, 1, Color(0.92, 0.92, 0.92))
	# 箭袋（背）
	_o_roundrect(img, 18, 44, 10, 24, 3, Color(0.5, 0.34, 0.20), Color(0.18, 0.1, 0.05))
	_o_tri(img, Vector2(19,40), Vector2(28,40), Vector2(23,30), Color(0.85, 0.68, 0.30), Color(0.3, 0.22, 0.08))
	# 眼
	_fill_circle(img, 44, 36, 2.2, PUPIL)
	_fill_circle(img, 52, 36, 2.2, PUPIL)
	_player_feet(img, frame, col)

static func _player_guardian(img, col, frame: int):
	var d = col.darkened(0.52); var x = col.darkened(0.22)
	# 头（露脸盔）
	_o_circle(img, C, 26, 10, SKIN, Color(0.3, 0.2, 0.14))
	_fill_roundrect(img, 38, 14, 20, 8, 3, col)   # 盔檐
	# 重铠躯干
	_o_poly(img, PackedVector2Array([Vector2(32,36), Vector2(64,36), Vector2(67,76), Vector2(29,76)]), col, d)
	_fill_poly(img, PackedVector2Array([Vector2(36,42), Vector2(60,42), Vector2(56,70), Vector2(40,70)]), x)
	# 正面巨盾（菱形盾面 + 十字筋）
	_o_poly(img, PackedVector2Array([Vector2(C,42), Vector2(68,58), Vector2(C,78), Vector2(28,58)]), Color(0.78, 0.62, 0.32), Color(0.28, 0.2, 0.08))
	_o_poly(img, PackedVector2Array([Vector2(C,47), Vector2(61,58), Vector2(C,72), Vector2(35,58)]), Color(0.9, 0.78, 0.46), Color(0.3, 0.22, 0.08))
	_fill_roundrect(img, C - 3, 48, 6, 20, 2, Color(0.35, 0.26, 0.10))
	_fill_roundrect(img, C - 9, 56, 18, 5, 2, Color(0.45, 0.32, 0.12))
	# 眼
	_fill_circle(img, 44, 26, 2.2, PUPIL)
	_fill_circle(img, 52, 26, 2.2, PUPIL)
	_player_feet(img, frame, col)

static func _player_mage(img, col, frame: int):
	var d = col.darkened(0.52); var x = col.darkened(0.2); var l = col.lightened(0.30)
	# 尖顶帽（弯尖 + 星饰）
	_o_poly(img, PackedVector2Array([Vector2(C,2), Vector2(32,28), Vector2(64,28)]), col, d)
	_o_roundrect(img, 30, 26, 36, 6, 3, col.darkened(0.3), d)
	_fill_circle(img, 56, 12, 2, Color(1.0, 0.9, 0.4))
	_fill_circle(img, 44, 18, 1.6, Color(1.0, 0.9, 0.4))
	# 头
	_fill_circle(img, C, 36, 8, SKIN)
	# 法袍（带符文带）
	_o_poly(img, PackedVector2Array([Vector2(33,44), Vector2(63,44), Vector2(67,80), Vector2(29,80)]), col, d)
	_fill_roundrect(img, 36, 52, 24, 5, 2, Color(0.4, 0.3, 0.6))   # 符文腰带
	for i in range(3):
		_fill_circle(img, 40 + i * 9, 54, 1.3, Color(1.0, 0.9, 0.5))
	# 法杖 + 浮空宝珠（带光弧）
	_o_roundrect(img, 70, 26, 5, 52, 2, Color(0.45, 0.3, 0.18), Color(0.16, 0.1, 0.05))
	_o_circle(img, 72, 22, 9, l, col.darkened(0.4))
	_fill_circle(img, 72, 22, 4, Color(0.85, 0.95, 1.0))
	# 眼
	_fill_circle(img, 44, 36, 2.2, PUPIL)
	_fill_circle(img, 52, 36, 2.2, PUPIL)
	_player_feet(img, frame, col)

static func _player_summoner(img, col, frame: int):
	var d = col.darkened(0.52); var x = col.darkened(0.22); var l = col.lightened(0.30)
	# 兜帽
	_o_poly(img, PackedVector2Array([Vector2(33,16), Vector2(63,16), Vector2(65,34), Vector2(31,34)]), col, d)
	_fill_circle(img, C, 36, 8, SKIN)
	# 法袍
	_o_poly(img, PackedVector2Array([Vector2(33,44), Vector2(63,44), Vector2(67,80), Vector2(29,80)]), col, d)
	# 召唤法阵（脚前光环 + 符文）
	_o_circle(img, C, 72, 15, col.darkened(0.35), d)
	_fill_circle(img, C, 72, 11, l)
	for i in range(6):
		var a = float(i) / 6.0 * TAU
		_fill_circle(img, C + cos(a) * 13, 72 + sin(a) * 13, 1.6, Color(1.0, 1.0, 0.85))
	# 随从宝珠（肩侧悬浮）
	_o_circle(img, 68, 40, 6, Color(0.75, 1.0, 0.95), col.darkened(0.4))
	_fill_circle(img, 68, 40, 2.6, Color(1.0, 1.0, 0.95))
	# 眼（神秘亮瞳）
	_fill_circle(img, 44, 36, 2.2, l)
	_fill_circle(img, 52, 36, 2.2, l)
	_player_feet(img, frame, col)

static func _player_healer(img, col, frame: int):
	var d = col.darkened(0.42); var x = col.darkened(0.16); var l = col.lightened(0.20)
	# 头巾（带圣徽）
	_o_poly(img, PackedVector2Array([Vector2(34,18), Vector2(62,18), Vector2(64,36), Vector2(32,36)]), col, d)
	_fill_circle(img, C, 38, 8, SKIN)
	_fill_circle(img, C, 22, 3, Color(1.0, 0.9, 0.5))
	# 圣袍 + 金边
	_o_poly(img, PackedVector2Array([Vector2(33,46), Vector2(63,46), Vector2(67,82), Vector2(29,82)]), col, d)
	_fill_poly(img, PackedVector2Array([Vector2(36,52), Vector2(60,52), Vector2(56,76), Vector2(40,76)]), x)
	_fill_roundrect(img, 31, 62, 34, 4, 2, Color(1.0, 0.85, 0.45))
	# 柔和光晕
	_fill_circle(img, C, 56, 26, Color(1.0, 0.95, 0.85, 0.14))
	# 权杖 + 十字圣徽
	_o_roundrect(img, 70, 30, 5, 48, 2, Color(0.8, 0.66, 0.30), Color(0.3, 0.22, 0.08))
	_fill_roundrect(img, 62, 26, 21, 6, 2, Color(0.95, 0.85, 0.45))
	_fill_roundrect(img, 71, 18, 6, 22, 2, Color(0.95, 0.85, 0.45))
	_fill_circle(img, 73, 16, 3, Color(1.0, 1.0, 0.85))
	# 眼
	_fill_circle(img, 44, 38, 2.2, PUPIL)
	_fill_circle(img, 52, 38, 2.2, PUPIL)
	_player_feet(img, frame, col)
