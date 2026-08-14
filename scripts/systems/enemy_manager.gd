extends Node
## EnemyManager —— 数据驱动的敌人系统（GDD §11.3 性能重构）
## 取代原本 800 个独立 Area2D 节点：敌人存为数据数组（Dictionary），
## 渲染交给单个 EnemyRender（CanvasItem._draw 批量画圆），命中/分离/接触
## 全部用手动空间哈希（SpatialHash）查询，不再依赖物理信号。
## 在 Web 单线程下把「800 节点 + 800 物理 body + 800 _draw」降到
## 1 个绘制表面 + 近似 O(n) 邻居查询。

signal enemy_died(enemy: Dictionary)

const DEFAULT_CELL: float = 64.0
const SEP_STRENGTH: float = 0.5   # 分离斥力强度（累加邻居排斥向量后乘此系数）
const SEP_BATCH: int = 350        # 每帧最多处理的分离敌人数（高数量下限制 CPU 开销）
const SpatialHashScript = preload("res://scripts/systems/spatial_hash.gd")

var hash = null   # SpatialHash 实例（preload 构造，避免 class_name 全局注册时序问题）
var enemies: Array = []            # 每个元素是一个敌人数据 Dictionary
var uid_to_index: Dictionary = {} # uid -> enemies 数组下标
var free_indices: Array = []      # 可复用的数组下标
var next_uid: int = 1
var _sep_cursor: int = 0      # 分离处理的轮转游标（每帧处理一批，隔帧覆盖全部）
var _enemy_tex_cache: Dictionary = {}    # "shape|color" -> 剪影贴图（按贴图合批渲染用）
const _CIRC_TEX_SIZE: int = 64

var render_node: Node2D = null
var EnemyRenderScript = preload("res://scripts/systems/enemy_render.gd")

# 静态障碍（数据驱动）：AABB 列表 {"pos":中心, "half":半尺寸}，用于阻挡敌人移动
var obstacles: Array = []
var map_min: Vector2 = Vector2(-1600.0, -1200.0)
var map_max: Vector2 = Vector2(1600.0, 1200.0)

func _ready() -> void:
	hash = SpatialHashScript.new(DEFAULT_CELL)

func _process(delta: float) -> void:
	if not GameManager.playing:
		return
	# 客机端不模拟：敌人世界完全由 host 广播的快照驱动
	if GameManager.net_mode == GameManager.NetMode.GUEST:
		return
	var players = GameManager.get_players_for_combat()
	if players.is_empty():
		return
	_update(delta, players)

## ---- 生命周期 ----
func attach_to_world(world: Node) -> void:
	if render_node != null and is_instance_valid(render_node):
		if render_node.get_parent() != null:
			render_node.get_parent().remove_child(render_node)
		render_node.queue_free()
	render_node = Node2D.new()
	render_node.name = "EnemyRender"
	render_node.set_script(EnemyRenderScript)
	render_node.z_index = 1
	world.add_child(render_node)

func reset() -> void:
	enemies.clear()
	uid_to_index.clear()
	free_indices.clear()
	next_uid = 1
	_sep_cursor = 0
	if hash != null:
		hash.cells.clear()

## ---- 静态障碍（数据驱动，与玩家物理墙对齐）----
func set_bounds(minv: Vector2, maxv: Vector2) -> void:
	map_min = minv
	map_max = maxv

## 整组替换障碍列表（main._ready 每次重开场景时调用，避免 autoload 持久化导致重复）
## 每个元素 {"pos":中心, "half":半尺寸}（轴对齐矩形）
func set_obstacles(list: Array) -> void:
	obstacles = list.duplicate(true)

## 把一个圆推出所有静态障碍 + 限制在地图边界内，返回修正后的位置
func resolve_obstacles(pos: Vector2, radius: float) -> Vector2:
	# 1) 地图边界夹紧
	pos.x = clamp(pos.x, map_min.x + radius, map_max.x - radius)
	pos.y = clamp(pos.y, map_min.y + radius, map_max.y - radius)
	# 2) 与每个 AABB 做圆-矩形分离
	for ob in obstacles:
		var c: Vector2 = ob.pos
		var h: Vector2 = ob.half
		var cx = clamp(pos.x, c.x - h.x, c.x + h.x)
		var cy = clamp(pos.y, c.y - h.y, c.y + h.y)
		var dx = pos.x - cx
		var dy = pos.y - cy
		var d2 = dx * dx + dy * dy
		if d2 < radius * radius:
			if d2 > 0.0001:
				var d = sqrt(d2)
				var push = radius - d
				pos.x += dx / d * push
				pos.y += dy / d * push
			else:
				# 圆心落在矩形内部：沿最小穿透轴推出
				var px = h.x + radius - abs(pos.x - c.x)
				var py = h.y + radius - abs(pos.y - c.y)
				if px < py:
					pos.x += sign(pos.x - c.x) * px
				else:
					pos.y += sign(pos.y - c.y) * py
	return pos

## 直接清空（复活清场用），不掉落、不计 kill
func clear() -> void:
	for e in enemies:
		if e.alive:
			hash.remove(e.uid, e.pos)
			e.alive = false
	enemies.clear()
	uid_to_index.clear()
	free_indices.clear()
	next_uid = 1
	_sep_cursor = 0
	if hash != null:
		hash.cells.clear()

## ---- 生成 ----
func spawn(eid: String, pos: Vector2, scale_m: float) -> int:
	if not DataTables.enemies.has(eid):
		return -1
	var d = DataTables.enemies[eid]
	var idx: int
	if free_indices.is_empty():
		idx = enemies.size()
		enemies.append({})
	else:
		idx = free_indices.pop_back()
	var e = enemies[idx]
	var uid = next_uid
	next_uid += 1
	e.uid = uid
	e.index = idx
	e.eid = eid
	e.pos = pos
	e.alive = true
	e.max_hp = float(d.hp) * scale_m * GameManager.diff.enemy_hp
	e.hp = e.max_hp
	e.speed = float(d.speed)
	e.contact_damage = float(d.damage) * scale_m * GameManager.diff.enemy_dmg
	e.exp_value = int(round(int(d.exp) * GameManager.diff.exp))
	e.coin_value = int(round(int(d.coin) * GameManager.diff.coin))
	e.size = float(d.size)
	e.color = Color.from_string(str(d.color), Color.RED)
	e.shape = str(d.get("shape", "imp"))
	e.tex = get_enemy_texture(e.shape, e.color)
	e.boss = bool(d.get("boss", false))
	e.elite = bool(d.get("elite", false)) or eid.begins_with("elite")
	e.flash_t = 0.0
	e.crit_pop_t = 0.0
	e.scale_mul = scale_m
	e.stuck_t = 0.0
	e.avoid_dir = Vector2.ZERO
	uid_to_index[uid] = idx
	hash.insert(uid, pos)
	return uid

func get_enemy(uid: int) -> Dictionary:
	if not uid_to_index.has(uid):
		return {}
	var idx = uid_to_index[uid]
	if idx < 0 or idx >= enemies.size():
		return {}
	var e = enemies[idx]
	if e.uid != uid or not e.alive:
		return {}
	return e

func get_enemy_pos(uid: int) -> Vector2:
	var e = get_enemy(uid)
	if e.is_empty():
		return Vector2.ZERO
	return e.pos

func get_nearest(from: Vector2) -> int:
	var best = -1
	var bd = INF
	for e in enemies:
		if not e.alive:
			continue
		var dd = e.pos.distance_squared_to(from)
		if dd < bd:
			bd = dd
			best = e.uid
	return best

func count_type(eid: String) -> int:
	var n = 0
	for e in enemies:
		if e.alive and e.eid == eid:
			n += 1
	return n

func alive_count() -> int:
	var n = 0
	for e in enemies:
		if e.alive:
			n += 1
	return n

## 普通怪（非精英、非 Boss）当前存活总数 —— 用于「普通怪按难度总上限」的限制
func count_normal() -> int:
	var n = 0
	for e in enemies:
		if e.alive and not e.elite and not e.boss:
			n += 1
	return n

## 返回半径内敌人 uid（精确距离判定已含敌人自身半径）
func query_near(pos: Vector2, radius: float) -> Array:
	var out: Array = []
	for uid in hash.query_radius(pos, radius):
		var e = get_enemy(uid)
		if e.is_empty():
			continue
		if e.pos.distance_to(pos) <= radius + e.size:
			out.append(uid)
	return out

## ---- 伤害 / 死亡 ----
func take_damage(uid: int, amount: float, kdir: Vector2 = Vector2.ZERO, kback: float = 0.0, source = null) -> void:
	var e = get_enemy(uid)
	if e.is_empty():
		return
	var dealt = amount
	# 暴击判定（唯一扣血出口，覆盖全部武器路径）；source 为造成伤害的玩家节点
	if source != null and source.crit_chance > 0.0 and randf() < source.crit_chance:
		dealt *= source.effective_crit_mult()
		e.crit_pop_t = 0.18
	e.hp -= dealt
	e.flash_t = 0.12
	# 吸血：造成实际伤害后按比例的回血
	if source != null and source.lifesteal > 0.0:
		source.heal(dealt * source.lifesteal)
	if kback > 0.0 and kdir != Vector2.ZERO:
		e.pos += kdir * kback * 0.04
	if e.hp <= 0.0:
		_kill(uid)

func _kill(uid: int) -> void:
	var e = get_enemy(uid)
	if e.is_empty():
		return
	var snapshot = {
		"uid": e.uid, "eid": e.eid, "pos": e.pos, "exp_value": e.exp_value,
		"coin_value": e.coin_value, "boss": e.boss, "elite": e.elite,
		"size": e.size, "color": e.color
	}
	hash.remove(uid, e.pos)
	uid_to_index.erase(uid)
	free_indices.append(e.index)
	e.alive = false
	enemy_died.emit(snapshot)

## 强制撤离某个敌人（Boss 阶段超时撤离用）：不掉落、不计击杀、不触发奖励
func despawn_uid(uid: int) -> void:
	var e = get_enemy(uid)
	if e.is_empty():
		return
	hash.remove(uid, e.pos)
	uid_to_index.erase(uid)
	free_indices.append(e.index)
	e.alive = false

## 障碍规避转向：返回敌人朝 target 的移动方向。
## 若正前方被墙/障碍阻挡，则在多个偏转角中选取「规避后位移最小」的方向绕行，
## 避免敌人直愣愣卡在墙上推不动（需求 #4：优化寻路）。仅在靠近障碍时才做探测，控制开销。
func _steer(e: Dictionary, target: Vector2) -> Vector2:
	var to = target - e.pos
	var dist = to.length()
	if dist < 0.001:
		return Vector2.ZERO
	var dir = to / dist
	var step = e.size + 26.0
	var ahead = e.pos + dir * step
	var push = resolve_obstacles(ahead, e.size).distance_to(ahead)
	if push <= 2.0:
		e.stuck_t = 0.0
		e.avoid_dir = Vector2.ZERO
		return dir
	# 被挡：在若干偏转角里挑最通畅（规避位移最小）的方向
	var best = dir
	var best_cost = push
	for ang in [0.6, -0.6, 1.2, -1.2, 1.9, -1.9, 2.6, -2.6]:
		var rd = dir.rotated(ang)
		var pa = e.pos + rd * step
		var cost = resolve_obstacles(pa, e.size).distance_to(pa)
		if cost < best_cost:
			best_cost = cost
			best = rd
	e.stuck_t += 1.0
	e.avoid_dir = best
	return best

## ---- 每帧更新 ----
## players：参与战斗的玩家节点数组（host 端 = 本人 + 各客机代理；客机端为空，由 host 模拟）。
## 每个敌人追逐「最近的玩家」；接触伤害对所有玩家分别结算。
func _update(delta: float, players: Array) -> void:
	# 1) 追踪玩家移动（朝最近玩家）+ 更新哈希位置
	for e in enemies:
		if not e.alive:
			continue
		var best_pos = players[0].global_position
		var bd = INF
		for p in players:
			var d = e.pos.distance_squared_to(p.global_position)
			if d < bd:
				bd = d
				best_pos = p.global_position
		# 障碍规避转向：被墙挡住时沿最通畅的偏转方向绕行，避免卡墙（需求 #4）
		var dir = _steer(e, best_pos)
		if dir.length_squared() > 0.0001:
			dir = dir.normalized()
		var old = e.pos
		e.pos += dir * e.speed * delta
		if e.flash_t > 0.0:
			e.flash_t = max(0.0, e.flash_t - delta)
		if e.crit_pop_t > 0.0:
			e.crit_pop_t = max(0.0, e.crit_pop_t - delta)
		hash.update(e.uid, old, e.pos)

	# 2) 分离斥力：每帧只处理一批敌人（游标轮转覆盖全部），限制高数量下的 CPU 开销。
	#    所有敌人仍每帧移动（步骤1已完成）；未轮到的敌人隔帧再分离，瞬时有轻微重叠但整体流畅。
	var done = 0
	var n = enemies.size()
	while done < SEP_BATCH:
		if n == 0:
			break
		var e = enemies[_sep_cursor]
		_sep_cursor = (_sep_cursor + 1) % n
		done += 1
		if not e.alive:
			continue
		var neigh = hash.query_radius(e.pos, e.size * 2.0 + 8.0)
		var push = Vector2.ZERO
		for nuid in neigh:
			if nuid == e.uid:
				continue
			var o = get_enemy(nuid)
			if o.is_empty():
				continue
			var diff = e.pos - o.pos
			var d = diff.length()
			var min_d = e.size + o.size
			if d > 0.0001 and d < min_d:
				push += diff / d * (min_d - d)
		e.pos += push * SEP_STRENGTH

	# 3) 障碍 / 边界阻挡（敌人也受墙与障碍物阻挡，与玩家物理墙对齐）
	for e in enemies:
		if not e.alive:
			continue
		e.pos = resolve_obstacles(e.pos, e.size)

	# 4) 玩家接触伤害：对每个玩家，查询其附近敌人并结算
	for p in players:
		var near = hash.query_radius(p.global_position, p.body_radius + 80.0)
		for nuid in near:
			var o = get_enemy(nuid)
			if o.is_empty():
				continue
			if o.pos.distance_to(p.global_position) <= o.size + p.body_radius:
				p.take_damage(o.contact_damage)

## 紧凑序列化：供 host 广播快照（数值四舍五入减体积；Color 转 [r,g,b] 数组便于 JSON）
func serialize_compact() -> Array:
	var out = []
	for e in enemies:
		if not e.alive:
			continue
		out.append({
			"e": e.eid,
			"x": round(e.pos.x * 10.0) / 10.0,
			"y": round(e.pos.y * 10.0) / 10.0,
			"hp": round(e.hp),
			"m": round(e.max_hp),
			"s": e.size,
			"c": [e.color.r, e.color.g, e.color.b],
			"b": 1 if e.boss else 0,
			"el": 1 if e.elite else 0,
			"f": round(e.flash_t * 100.0) / 100.0,
			"cr": round(e.crit_pop_t * 100.0) / 100.0
		})
	return out

## ---- 渲染 ----
## 按敌人 shape 程序化生成「哥特剪影」贴图（每种怪独特轮廓 + 眼睛），缓存 key=shape|color。
## 渲染时仍按贴图（e.tex）分组连续 draw_texture_rect，Godot 2D 自动合批，
## 绘制调用数 ~= 怪物种数（≤11），Web 单线程下保持低开销（性能没回归）。
## 贴图在首次生成某 (shape,color) 时一次性光栅化（手写像素基元），之后复用。

func get_enemy_texture(shape: String, col: Color) -> Texture2D:
	var key = shape + "|" + col.to_html()
	if _enemy_tex_cache.has(key):
		return _enemy_tex_cache[key]
	var S = _CIRC_TEX_SIZE
	var img = Image.create(S, S, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var dark = col.darkened(0.5)
	var light = col.lightened(0.4)
	var eye_w = Color(0.95, 0.92, 0.80, 1.0)
	var pupil = Color(0.08, 0.06, 0.10, 1.0)
	match shape:
		"imp":     _shape_imp(img, col, dark, light, eye_w, pupil)
		"fast":    _shape_fast(img, col, dark, light, eye_w, pupil)
		"brute":   _shape_brute(img, col, dark, light, eye_w, pupil)
		"wraith":  _shape_wraith(img, col, dark, light, eye_w, pupil)
		"swift":   _shape_swift(img, col, dark, light, eye_w, pupil)
		"elite":   _shape_elite(img, col, dark, light, eye_w, pupil)
		"stone":   _shape_stone(img, col, dark, light, eye_w, pupil)
		"corrode": _shape_corrode(img, col, dark, light, eye_w, pupil)
		"boss":    _shape_boss(img, col, dark, light, eye_w, pupil)
		_:         _shape_imp(img, col, dark, light, eye_w, pupil)
	var tex = ImageTexture.create_from_image(img)
	_enemy_tex_cache[key] = tex
	return tex

## ---- 像素基元（手写光栅化，Image 无 draw_* 原语）----
func _set_px(img: Image, x: int, y: int, col: Color) -> void:
	if x >= 0 and x < img.get_width() and y >= 0 and y < img.get_height():
		img.set_pixel(x, y, col)

func _fill_circle(img: Image, cx: float, cy: float, r: float, col: Color) -> void:
	var r2 = r * r
	for y in range(int(cy - r - 1), int(cy + r + 1) + 1):
		for x in range(int(cx - r - 1), int(cx + r + 1) + 1):
			var dx = x - cx; var dy = y - cy
			if dx * dx + dy * dy <= r2:
				_set_px(img, x, y, col)

func _fill_ellipse(img: Image, cx: float, cy: float, rx: float, ry: float, col: Color) -> void:
	for y in range(int(cy - ry - 1), int(cy + ry + 1) + 1):
		for x in range(int(cx - rx - 1), int(cx + rx + 1) + 1):
			var dx = (x - cx) / rx; var dy = (y - cy) / ry
			if dx * dx + dy * dy <= 1.0:
				_set_px(img, x, y, col)

func _fill_roundrect(img: Image, x: float, y: float, w: float, h: float, rad: float, col: Color) -> void:
	for yy in range(int(y), int(y + h) + 1):
		for xx in range(int(x), int(x + w) + 1):
			var nx = min(max(float(xx), x + rad), x + w - rad)
			var ny = min(max(float(yy), y + rad), y + h - rad)
			var dx = xx - nx; var dy = yy - ny
			if dx * dx + dy * dy <= rad * rad:
				_set_px(img, xx, yy, col)

func _fill_tri(img: Image, p0: Vector2, p1: Vector2, p2: Vector2, col: Color) -> void:
	var minx = int(min(p0.x, p1.x, p2.x)); var maxx = int(max(p0.x, p1.x, p2.x))
	var miny = int(min(p0.y, p1.y, p2.y)); var maxy = int(max(p0.y, p1.y, p2.y))
	for y in range(miny, maxy + 1):
		for x in range(minx, maxx + 1):
			var w0 = (x - p1.x) * (p2.y - p1.y) - (p2.x - p1.x) * (y - p1.y)
			var w1 = (x - p2.x) * (p0.y - p2.y) - (p0.x - p2.x) * (y - p2.y)
			var w2 = (x - p0.x) * (p1.y - p0.y) - (p1.x - p0.x) * (y - p0.y)
			if (w0 >= 0 and w1 >= 0 and w2 >= 0) or (w0 <= 0 and w1 <= 0 and w2 <= 0):
				_set_px(img, x, y, col)

func _fill_poly(img: Image, pts: PackedVector2Array, col: Color) -> void:
	var minx = 9999.0; var maxx = -9999.0; var miny = 9999.0; var maxy = -9999.0
	for p in pts:
		minx = min(minx, p.x); maxx = max(maxx, p.x)
		miny = min(miny, p.y); maxy = max(maxy, p.y)
	for y in range(int(miny), int(maxy) + 1):
		for x in range(int(minx), int(maxx) + 1):
			if _point_in_poly(float(x), float(y), pts):
				_set_px(img, x, y, col)

func _point_in_poly(x: float, y: float, pts: PackedVector2Array) -> bool:
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

## ---- 各 shape 的剪影构图（64×64 画布，中心约 32）----
func _shape_imp(img, col, dark, light, eye_w, pupil):
	_fill_circle(img, 32, 36, 23, dark)        # 描边
	_fill_circle(img, 32, 35, 21, col)         # 身体
	_fill_tri(img, Vector2(20,16), Vector2(26,16), Vector2(18,4), dark)   # 左角
	_fill_tri(img, Vector2(44,16), Vector2(38,16), Vector2(46,4), dark)   # 右角
	_fill_ellipse(img, 32, 42, 11, 9, light)  # 肚皮高光
	_fill_circle(img, 25, 33, 4, eye_w); _fill_circle(img, 25, 33, 2, pupil)
	_fill_circle(img, 39, 33, 4, eye_w); _fill_circle(img, 39, 33, 2, pupil)

func _shape_fast(img, col, dark, light, eye_w, pupil):
	_fill_ellipse(img, 32, 36, 13, 21, col)
	_fill_tri(img, Vector2(24,46), Vector2(40,46), Vector2(32,60), dark)  # 尾
	_fill_ellipse(img, 32, 28, 7, 4, light)
	_fill_circle(img, 32, 26, 3, eye_w)

func _shape_brute(img, col, dark, light, eye_w, pupil):
	_fill_roundrect(img, 8, 16, 48, 40, 12, dark)
	_fill_roundrect(img, 10, 18, 44, 36, 10, col)
	_fill_roundrect(img, 14, 20, 36, 10, 6, light)
	_fill_ellipse(img, 24, 34, 6, 3, pupil)
	_fill_ellipse(img, 40, 34, 6, 3, pupil)

func _shape_wraith(img, col, dark, light, eye_w, pupil):
	_fill_circle(img, 32, 30, 20, col)
	_fill_tri(img, Vector2(12,44), Vector2(22,44), Vector2(17,58), col)
	_fill_tri(img, Vector2(22,44), Vector2(32,44), Vector2(27,58), col)
	_fill_tri(img, Vector2(32,44), Vector2(42,44), Vector2(37,58), col)
	_fill_tri(img, Vector2(42,44), Vector2(52,44), Vector2(47,58), col)
	_fill_circle(img, 25, 28, 4, eye_w); _fill_circle(img, 25, 28, 2, pupil)
	_fill_circle(img, 39, 28, 4, eye_w); _fill_circle(img, 39, 28, 2, pupil)

func _shape_swift(img, col, dark, light, eye_w, pupil):
	_fill_tri(img, Vector2(32,8), Vector2(14,52), Vector2(50,52), col)
	_fill_tri(img, Vector2(32,14), Vector2(20,50), Vector2(44,50), dark)
	_fill_circle(img, 32, 26, 3, eye_w)

func _shape_elite(img, col, dark, light, eye_w, pupil):
	_fill_circle(img, 32, 36, 19, dark)
	_fill_circle(img, 32, 35, 17, col)
	for i in range(8):
		var a = float(i) / 8.0 * TAU
		var bx = 32 + cos(a) * 17; var by = 35 + sin(a) * 17
		var tx = 32 + cos(a) * 26; var ty = 35 + sin(a) * 26
		var pa = a + 0.25; var pb = a - 0.25
		_fill_tri(img, Vector2(bx,by), Vector2(32+cos(pa)*17, 35+sin(pa)*17), Vector2(tx,ty), dark)
		_fill_tri(img, Vector2(bx,by), Vector2(32+cos(pb)*17, 35+sin(pb)*17), Vector2(tx,ty), dark)
	_fill_circle(img, 26, 34, 4, eye_w); _fill_circle(img, 26, 34, 2, pupil)
	_fill_circle(img, 38, 34, 4, eye_w); _fill_circle(img, 38, 34, 2, pupil)

func _shape_stone(img, col, dark, light, eye_w, pupil):
	var pts = PackedVector2Array(); var R = 26
	for i in range(6):
		var a = float(i) / 6.0 * TAU - PI / 2.0
		pts.append(Vector2(32 + cos(a) * R, 34 + sin(a) * R))
	_fill_poly(img, pts, dark)
	var pts2 = PackedVector2Array()
	for i in range(6):
		var a = float(i) / 6.0 * TAU - PI / 2.0
		pts2.append(Vector2(32 + cos(a) * (R - 3), 34 + sin(a) * (R - 3)))
	_fill_poly(img, pts2, col)
	_fill_poly(img, [Vector2(20,22), Vector2(34,20), Vector2(22,34)], light)
	_fill_circle(img, 26, 34, 3, eye_w); _fill_circle(img, 38, 34, 3, eye_w)

func _shape_corrode(img, col, dark, light, eye_w, pupil):
	_fill_circle(img, 32, 34, 20, dark)
	_fill_circle(img, 32, 34, 18, col)
	for i in range(10):
		var a = float(i) / 10.0 * TAU
		var len = 24 + (i % 3) * 4
		var bx = 32 + cos(a) * 18; var by = 34 + sin(a) * 18
		var tx = 32 + cos(a) * len; var ty = 34 + sin(a) * len
		var pa = a + 0.18; var pb = a - 0.18
		_fill_tri(img, Vector2(bx,by), Vector2(32+cos(pa)*18, 34+sin(pa)*18), Vector2(tx,ty), dark)
		_fill_tri(img, Vector2(bx,by), Vector2(32+cos(pb)*18, 34+sin(pb)*18), Vector2(tx,ty), dark)
	_fill_circle(img, 26, 34, 4, light); _fill_circle(img, 26, 34, 2, pupil)
	_fill_circle(img, 38, 34, 4, light); _fill_circle(img, 38, 34, 2, pupil)

func _shape_boss(img, col, dark, light, eye_w, pupil):
	_fill_tri(img, Vector2(18,18), Vector2(28,22), Vector2(14,2), dark)   # 左角
	_fill_tri(img, Vector2(46,18), Vector2(36,22), Vector2(50,2), dark)   # 右角
	_fill_circle(img, 32, 38, 26, dark)
	_fill_circle(img, 32, 37, 24, col)
	_fill_ellipse(img, 32, 44, 12, 9, light)
	_fill_circle(img, 24, 34, 6, eye_w); _fill_circle(img, 24, 34, 3, Color(0.9,0.1,0.1,1))
	_fill_circle(img, 40, 34, 6, eye_w); _fill_circle(img, 40, 34, 3, Color(0.9,0.1,0.1,1))
	_fill_tri(img, Vector2(28,48), Vector2(34,48), Vector2(31,56), eye_w)  # 獠牙
	_fill_tri(img, Vector2(34,48), Vector2(40,48), Vector2(37,56), eye_w)


func draw_obstacles(node: CanvasItem) -> void:
	for ob in obstacles:
		var c: Vector2 = ob.pos
		var h: Vector2 = ob.half
		var topleft = Vector2(c.x - h.x, c.y - h.y)
		var size = Vector2(h.x * 2.0, h.y * 2.0)
		# 阴影
		node.draw_rect(Rect2(topleft + Vector2(5, 7), size), Color(0, 0, 0, 0.35))
		# 石身
		node.draw_rect(Rect2(topleft, size), Color(0.30, 0.28, 0.34, 1.0))
		# 顶部高光（受光面）
		node.draw_rect(Rect2(topleft, Vector2(size.x, min(10.0, size.y))), Color(0.46, 0.42, 0.52, 1.0))
		# 边框
		node.draw_rect(Rect2(topleft, size), Color(0.58, 0.52, 0.64, 1.0), false, 2.0)
		# 符文标记
		node.draw_rect(Rect2(c - Vector2(8, 8), Vector2(16, 16)), Color(0.6, 0.3, 0.5, 0.55), false, 2.0)

func draw_enemies(node: CanvasItem) -> void:
	# 按颜色贴图分组，连续绘制同类敌人 -> 触发 Godot 2D 自动合批（O(n) 绘制 -> ~颜色数）
	var groups = {}
	for e in enemies:
		if not e.alive:
			continue
		var tex = e.tex
		if tex == null:
			tex = get_enemy_texture(e.shape, e.color)
		if not groups.has(tex):
			groups[tex] = []
		var s = e.size * 2.0
		groups[tex].append(Rect2(e.pos.x - e.size, e.pos.y - e.size, s, s))
	for tex in groups:
		for r in groups[tex]:
			node.draw_texture_rect(tex, r, false)
	# 受击闪白：仅少数敌人短暂触发，直接用 draw_circle（成本低）
	for e in enemies:
		if e.alive and e.flash_t > 0.0:
			node.draw_circle(e.pos, e.size, Color(1, 1, 1, e.flash_t))
	# 暴击命中：短暂放大白圈（与闪白区分，提示暴击发生）
	for e in enemies:
		if e.alive and e.crit_pop_t > 0.0:
			var k = e.crit_pop_t / 0.18
			node.draw_circle(e.pos, e.size * (1.0 + 0.4 * k), Color(1, 1, 1, 0.55 * k))
	# Boss / 精英 血条
	for e in enemies:
		if e.alive and (e.boss or e.elite):
			var w = max(30.0, e.size * 2.0)
			var ratio = clamp(e.hp / e.max_hp, 0.0, 1.0)
			node.draw_rect(Rect2(e.pos.x - w / 2.0, e.pos.y - e.size - 8.0, w, 4.0), Color(0.2, 0.2, 0.2, 0.8))
			node.draw_rect(Rect2(e.pos.x - w / 2.0, e.pos.y - e.size - 8.0, w * ratio, 4.0), Color(0.9, 0.2, 0.2, 0.9))
