extends Node
## EnemyManager —— 数据驱动的敌人系统（GDD §11.3 性能重构）
## 取代原本 800 个独立 Area2D 节点：敌人存为数据数组（Dictionary），
## 渲染交给单个 EnemyRender（CanvasItem._draw 批量画圆），命中/分离/接触
## 全部用手动空间哈希（SpatialHash）查询，不再依赖物理信号。
## 在 Web 单线程下把「800 节点 + 800 物理 body + 800 _draw」降到
## 1 个绘制表面 + 近似 O(n) 邻居查询。

signal enemy_died(enemy: Dictionary)
signal enemy_fire(epos: Vector2, edir: Vector2, espeed: float, edmg: float, ecol: Color)
signal enemy_explode(epos: Vector2, eradius: float, edmg: float)

const DEFAULT_CELL: float = 64.0
const SEP_STRENGTH: float = 0.5   # 分离斥力强度（累加邻居排斥向量后乘此系数）
const SEP_BATCH: int = 350        # 每帧最多处理的分离敌人数（高数量下限制 CPU 开销）
const SpatialHashScript = preload("res://scripts/systems/spatial_hash.gd")
const CreatureVisual = preload("res://scripts/systems/creature_visual.gd")

var hash = null   # SpatialHash 实例（preload 构造，避免 class_name 全局注册时序问题）
var enemies: Array = []            # 每个元素是一个敌人数据 Dictionary
var explosions: Array = []          # 自爆怪爆炸特效 [{pos, r, t}]，由 host 端 _update 计时
var hit_effects: Array = []         # 打击特效 [{pos, t, crit, dir}]：受击扩散环+火花，0.25s 衰减
var lightning_fx: Array = []        # 连锁闪电特效 [{pts: PackedVector2Array, t, super}]，0.22s 衰减
var uid_to_index: Dictionary = {} # uid -> enemies 数组下标
var free_indices: Array = []      # 可复用的数组下标
var next_uid: int = 1
var _sep_cursor: int = 0      # 分离处理的轮转游标（每帧处理一批，隔帧覆盖全部）

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
	e.tex = get_enemy_texture(e.shape, e.color, GameManager.map_id)
	e.boss = bool(d.get("boss", false))
	e.elite = bool(d.get("elite", false)) or eid.begins_with("elite")
	e.flash_t = 0.0
	e.crit_pop_t = 0.0
	e.anim_t = randf() * 10.0   # 动画计时器（随机起点，避免全体敌人同相摆动）
	e.attack_t = 0.0            # 攻击姿态计时（>0 时使用攻击帧 + 攻击脉冲）
	e.scale_mul = scale_m
	e.stuck_t = 0.0
	e.avoid_dir = Vector2.ZERO
	e.ai = str(d.get("ai", "chase"))
	e.shield = float(d.get("shield", 0.0))
	e.max_shield = e.shield
	e.burn_t = 0.0
	e.burn_dps = 0.0
	e.freeze_t = 0.0
	e.freeze_slow = 0.0
	e.regen = 0.0
	# 怪物黑色词条：强化全体怪物（hp/伤害/速度/护盾/再生），仅当选了黑词条时生效
	if AffixManager.active_monster.size() > 0:
		var mm = AffixManager.monster_enemy_mods()
		e.max_hp *= mm.hp_mult
		e.hp = e.max_hp
		e.contact_damage *= mm.damage_mult * mm.touch_dmg_mult
		e.speed *= mm.speed_mult
		if mm.shield_add > 0.0:
			e.shield += mm.shield_add
			e.max_shield = e.shield
		e.regen = mm.regen
	e.suicide = bool(d.get("suicide", false)) or (str(d.get("ai", "")) == "suicide")
	e.blast_radius = float(d.get("blast_radius", 0.0))
	e.fire_interval = float(d.get("fire_interval", 2.0))
	e.fire_cd = 0.0
	e.proj_speed = float(d.get("projectile_speed", 240.0))
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
## extra_pen：本发攻击额外护盾穿透（来自武器数据 shield_pen），与玩家属性穿透叠加。
## 护盾机制：pen（0~1）比例的伤害直接打血，其余先扣护盾；pen=0 全打盾、pen=1 无视护盾。
func take_damage(uid: int, amount: float, kdir: Vector2 = Vector2.ZERO, kback: float = 0.0, source = null, extra_pen: float = 0.0, crit_bonus: float = 0.0) -> void:
	var e = get_enemy(uid)
	if e.is_empty():
		return
	var dealt = amount
	# 暴击判定（唯一扣血出口，覆盖全部武器路径）；source 为造成伤害的玩家节点。
	# crit_bonus 为词条附加暴击率（weapon_base 的 crit_up flag 累加）。
	var crit_roll = 0.0
	if source != null and source.crit_chance > 0.0:
		crit_roll = source.crit_chance + crit_bonus
	var was_crit = false
	if crit_roll > 0.0 and randf() < crit_roll:
		dealt *= source.effective_crit_mult()
		e.crit_pop_t = 0.18
		was_crit = true
	# 护盾穿透：pen 比例的伤害直接打血，其余先扣护盾
	var pen = clamp(extra_pen, 0.0, 1.0)
	if source != null and source.has_method("get_shield_pen"):
		pen = clamp(source.get_shield_pen() + extra_pen, 0.0, 1.0)
	var hp_part = dealt * pen
	var shield_part = dealt * (1.0 - pen)
	if e.shield > 0.0 and shield_part > 0.0:
		var absorbed = min(e.shield, shield_part)
		e.shield -= absorbed
		shield_part -= absorbed
	hp_part += shield_part
	e.hp -= hp_part
	e.flash_t = 0.12
	# 打击特效（受击扩散环 + 火花）：统一伤害出口触发，含暴击强化
	hit_effects.append({
		"pos": e.pos, "t": 0.0, "crit": was_crit,
		"dir": kdir if kdir != Vector2.ZERO else Vector2(randf() - 0.5, randf() - 0.5).normalized()
	})
	if hit_effects.size() > 60:
		hit_effects.pop_front()
	# 吸血：造成实际伤害后按比例的回血
	if source != null and source.lifesteal > 0.0:
		source.heal(hp_part * source.lifesteal)
	if kback > 0.0 and kdir != Vector2.ZERO:
		e.pos += kdir * kback * 0.04
	if e.hp <= 0.0:
		if e.suicide:
			_explode(uid)
		else:
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

## 自爆怪爆炸：对范围内所有玩家结算 AoE（main._on_enemy_explode 处理），然后正常死亡掉落
func _explode(uid: int) -> void:
	var e = get_enemy(uid)
	if e.is_empty():
		return
	enemy_explode.emit(e.pos, e.blast_radius, float(e.contact_damage))
	_kill(uid)

## ---------- 词条命中特效（由 AffixManager._fx_trigger 调用）----------

## 范围爆发：对 uid 周围 radius 内的敌人（不含自身）造成 dmg（质变 explode 特效）
func aoe_burst(uid: int, dmg: float, radius: float, source) -> void:
	var center = get_enemy_pos(uid)
	if center == Vector2.ZERO:
		return
	for nuid in query_near(center, radius):
		if nuid == uid:
			continue
		take_damage(nuid, dmg, Vector2.ZERO, 0.0, source, 0.0)

## 连锁：从 uid 起，向 jumps 个最近的未命中敌人跳跃造成伤害（质变 chain 特效）
## is_super：超质变时闪电更华丽（更多跳数由调用方控制，此处决定配色/粗细）
func chain_to(uid: int, dmg: float, jumps: int, source, is_super: bool = false) -> void:
	var hit = {uid: true}
	var cur = uid
	var pts: PackedVector2Array = [get_enemy_pos(cur)]
	for _i in range(jumps):
		var cpos = get_enemy_pos(cur)
		if cpos == Vector2.ZERO:
			break
		var next_uid = -1
		var bd = INF
		for e in enemies:
			if not e.alive or hit.has(e.uid):
				continue
			var dd = e.pos.distance_squared_to(cpos)
			if dd < bd:
				bd = dd
				next_uid = e.uid
		if next_uid < 0:
			break
		hit[next_uid] = true
		take_damage(next_uid, dmg, Vector2.ZERO, 0.0, source, 0.0)
		pts.append(get_enemy_pos(next_uid))
		cur = next_uid
	# 连锁闪电可视化：锯齿折线（渲染端按 t 抖动 + 配色区分质变/超质变）
	if pts.size() >= 2:
		lightning_fx.append({"pts": pts, "t": 0.0, "super": is_super})
		if lightning_fx.size() > 12:
			lightning_fx.pop_front()

## 上状态：burn=持续灼烧 DoT（power 为每秒伤害，dur 持续秒数）；freeze=减速（power 0~1 -> 最大 60% 减速）
func add_status(uid: int, kind: String, dur: float, power: float) -> void:
	var e = get_enemy(uid)
	if e.is_empty():
		return
	if kind == "burn":
		e.burn_t = max(e.burn_t, dur)
		e.burn_dps = max(e.burn_dps, power)
	elif kind == "freeze":
		e.freeze_t = max(e.freeze_t, dur)
		e.freeze_slow = clamp(power, 0.0, 1.0) * 0.6

## 破盾重击：直接削减敌人护盾（无视血量），用于质变 shield_break 特效
func shield_strike(uid: int, dmg: float, source) -> void:
	var e = get_enemy(uid)
	if e.is_empty():
		return
	e.shield = max(0.0, e.shield - dmg)

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

## 远程怪走位：与目标保持 ~200 距离（太近后撤 / 太远靠近 / 适中横向走位），并叠加避障。
func _steer_ranged(e: Dictionary, to: Vector2, dist: float) -> Vector2:
	var desired = 200.0
	var dir: Vector2
	if dist < 0.001:
		return Vector2.ZERO
	if dist < desired - 40.0:
		dir = -to.normalized()                      # 拉开距离
	elif dist > desired + 40.0:
		dir = to.normalized()                       # 靠近
	else:
		var side = 1.0 if int(e.uid) % 2 == 0 else -1.0
		dir = Vector2(-to.y, to.x).normalized() * side   # 横向走位
	# 避障：若正前方被墙挡，改用通用规避方向
	var step = e.size + 26.0
	var ahead = e.pos + dir * step
	var push = resolve_obstacles(ahead, e.size).distance_to(ahead)
	if push > 2.0:
		dir = _steer(e, e.pos + to)
	return dir

## ---- 每帧更新 ----
## players：参与战斗的玩家节点数组（host 端 = 本人 + 各客机代理；客机端为空，由 host 模拟）。
## 每个敌人追逐「最近的玩家」；接触伤害对所有玩家分别结算。
func _update(delta: float, players: Array) -> void:
	# 0) 状态tick：灼烧 DoT / 冰冻计时 / 再生（在移动前结算，可能直接致死）
	for e in enemies:
		if not e.alive:
			continue
		if e.burn_t > 0.0 and e.burn_dps > 0.0:
			e.burn_t -= delta
			e.hp -= e.burn_dps * delta
			e.flash_t = max(e.flash_t, 0.05)
			if e.hp <= 0.0:
				_kill(e.uid)
				continue
		if e.freeze_t > 0.0:
			e.freeze_t -= delta
		if e.regen > 0.0 and e.hp < e.max_hp:
			e.hp = min(e.max_hp, e.hp + e.regen * delta)
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
		var to = best_pos - e.pos
		var dist = to.length()
		# 按 ai 分支计算移动方向
		var dir: Vector2
		if e.ai == "ranged":
			dir = _steer_ranged(e, to, dist)
		else:
			# chase / suicide 都直奔玩家
			dir = _steer(e, best_pos)
		if dir.length_squared() > 0.0001:
			dir = dir.normalized()
		var old = e.pos
		var spd = e.speed
		if e.freeze_t > 0.0:
			spd *= (1.0 - e.freeze_slow)
		e.pos += dir * spd * delta
		# 远程怪开火（host 端，信号交给 main 生成敌弹）
		if e.ai == "ranged":
			e.fire_cd -= delta
			if e.fire_cd <= 0.0 and dist < 520.0:
				var d2 = to.normalized()
				enemy_fire.emit(e.pos + d2 * e.size, d2, e.proj_speed, e.contact_damage, e.color)
				e.fire_cd = e.fire_interval
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
			var d = o.pos.distance_to(p.global_position)
			# 自爆怪：进入爆炸半径即引爆（已对范围内所有玩家结算 AoE），随后移除
			if o.suicide and d <= o.blast_radius + p.body_radius:
				_explode(nuid)
				continue
			if d <= o.size + p.body_radius:
				o.attack_t = 0.35   # 攻击姿态：切攻击帧 + 红色凶光（动画表现）
				p.take_damage(o.contact_damage)

	# 5) 特效计时：爆炸光环 / 打击特效 / 连锁闪电 / 敌人动画与攻击姿态
	for i in range(explosions.size() - 1, -1, -1):
		explosions[i].t += delta
		if explosions[i].t >= 0.35:
			explosions.remove_at(i)
	for i in range(hit_effects.size() - 1, -1, -1):
		hit_effects[i].t += delta
		if hit_effects[i].t >= 0.25:
			hit_effects.remove_at(i)
	for i in range(lightning_fx.size() - 1, -1, -1):
		lightning_fx[i].t += delta
		if lightning_fx[i].t >= 0.22:
			lightning_fx.remove_at(i)
	for e in enemies:
		if not e.alive:
			continue
		e.anim_t += delta
		if e.attack_t > 0.0:
			e.attack_t = max(0.0, e.attack_t - delta)

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
## 怪物「模型」由 CreatureVisual 统一生成（见 creature_visual.gd）：
## get_enemy_texture 仅做委托（含 world 世界风格与 frame 动画帧），贴图缓存也在 CreatureVisual 内。

func get_enemy_texture(shape: String, col: Color, world: String = "", frame: int = 0) -> Texture2D:
	# 怪物模型渲染已集中到 CreatureVisual（与玩家立绘统一管理，见 creature_visual.gd）
	# world 参数让同一 shape 在三界呈现不同「边缘语言 + 母题」；frame 驱动走路/攻击动画帧
	return CreatureVisual.get_enemy_texture(shape, col, world, frame)


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
	# 按颜色贴图分组，连续绘制同类敌人 -> 触发 Godot 2D 自动合批（O(n) 绘制 -> ~贴图数）
	# 动态模型：每实体按动画计时器选帧（走路 0/1 交替；攻击中切攻击帧 2 + 体型脉冲放大）
	var groups = {}
	for e in enemies:
		if not e.alive:
			continue
		var frame = 2 if e.attack_t > 0.0 else (int(e.anim_t * 4.0) % 2)
		var tex = get_enemy_texture(e.shape, e.color, GameManager.map_id, frame)
		if tex == null:
			tex = e.tex
		if not groups.has(tex):
			groups[tex] = []
		# 视觉放大 1.2x（保留命中判定 e.size 不变，仅观感变大）；攻击中轻微脉冲
		var vs = e.size * 2.0 * 1.2
		if e.attack_t > 0.0:
			vs *= 1.0 + 0.12 * sin(e.anim_t * 30.0)
		groups[tex].append(Rect2(e.pos.x - vs / 2.0, e.pos.y - vs / 2.0, vs, vs))
	for tex in groups:
		for r in groups[tex]:
			node.draw_texture_rect(tex, r, false)
	# 受击闪白：贴图整体提白（modulate）——不再是盖在模型上的白圆环
	for e in enemies:
		if e.alive and e.flash_t > 0.0:
			var frame = 2 if e.attack_t > 0.0 else (int(e.anim_t * 4.0) % 2)
			var tex2 = get_enemy_texture(e.shape, e.color, GameManager.map_id, frame)
			var vs2 = e.size * 2.0 * 1.2
			node.draw_texture_rect(tex2, Rect2(e.pos.x - vs2 / 2.0, e.pos.y - vs2 / 2.0, vs2, vs2), false,
				Color(1.0, 1.0, 1.0, min(0.85, e.flash_t * 7.0)))
	# 护盾：带盾敌人画青色护盾环 + 护盾条（护盾穿透机制可视化）
	for e in enemies:
		if e.alive and e.shield > 0.0:
			node.draw_arc(e.pos, e.size + 5.0, 0, TAU, 26, Color(0.45, 0.85, 1.0, 0.55), 2.5)
			var sw = max(30.0, e.size * 2.0)
			var sr = clamp(e.shield / e.max_shield, 0.0, 1.0) if e.max_shield > 0.0 else 1.0
			var by = e.pos.y - e.size - 13.0
			node.draw_rect(Rect2(e.pos.x - sw / 2.0, by, sw, 3.0), Color(0.12, 0.30, 0.45, 0.85))
			node.draw_rect(Rect2(e.pos.x - sw / 2.0, by, sw * sr, 3.0), Color(0.45, 0.85, 1.0, 0.95))

	# Boss / 精英 血条
	for e in enemies:
		if e.alive and (e.boss or e.elite):
			var w = max(30.0, e.size * 2.0)
			var ratio = clamp(e.hp / e.max_hp, 0.0, 1.0)
			node.draw_rect(Rect2(e.pos.x - w / 2.0, e.pos.y - e.size - 8.0, w, 4.0), Color(0.2, 0.2, 0.2, 0.8))
			node.draw_rect(Rect2(e.pos.x - w / 2.0, e.pos.y - e.size - 8.0, w * ratio, 4.0), Color(0.9, 0.2, 0.2, 0.9))

	# 自爆怪爆炸特效（扩散光环，0.35s 内衰减）
	for ex in explosions:
		var k = 1.0 - ex.t / 0.35
		if k <= 0.0:
			continue
		var rr = ex.r * (1.0 + (1.0 - k) * 0.25)
		node.draw_circle(ex.pos, rr, Color(1.0, 0.55, 0.2, 0.18 * k))
		node.draw_arc(ex.pos, rr, 0, TAU, 28, Color(1.0, 0.8, 0.3, 0.85 * k), 3.0)

	# 打击特效（受击扩散环 + 火花；暴击=金色 + 更大）：0.25s 衰减
	for he in hit_effects:
		var k = 1.0 - he.t / 0.25
		if k <= 0.0:
			continue
		var rr = (6.0 if not he.crit else 9.0) + (1.0 - k) * 15.0
		var hcol = Color(1.0, 0.85, 0.35) if he.crit else Color(1.0, 1.0, 1.0)
		node.draw_arc(he.pos, rr, 0, TAU, 18, Color(hcol.r, hcol.g, hcol.b, 0.7 * k), 2.0)
		node.draw_circle(he.pos, rr * 0.4, Color(1.0, 1.0, 1.0, 0.22 * k))
		var dd = he.dir
		for i in range(3):
			var sa = (i - 1.0) * 0.7 + he.t * 8.0
			var sp = he.pos + dd.rotated(sa) * (rr + 4.0)
			node.draw_line(he.pos, sp, Color(hcol.r, hcol.g, hcol.b, 0.55 * k), 1.5)

	# 连锁闪电（质变 chain 特效）：锯齿折线逐段跳动；质变=青白，超质变=彩虹流转
	var ltime = Time.get_ticks_msec() / 1000.0
	for lz in lightning_fx:
		var k = 1.0 - lz.t / 0.22
		if k <= 0.0:
			continue
		var pts = lz.pts
		for seg in range(pts.size() - 1):
			var a = pts[seg]; var b = pts[seg + 1]
			var dirv = (b - a).normalized()
			var perp = dirv.orthogonal()
			var mid = (a + b) * 0.5
			var p0 = a + perp * sin(ltime * 37.0 + float(seg) * 2.3) * 3.0
			var p1 = mid + perp * (5.0 + 6.0 * (0.5 + 0.5 * sin(ltime * 40.0 + float(seg) * 3.7)))
			var p2 = b + perp * sin(ltime * 41.0 + float(seg) * 5.1) * 3.0
			var zig = PackedVector2Array([p0, p1, p2])
			var glow_col: Color
			if lz.super:
				glow_col = Color.from_hsv(fmod(ltime * 2.5 + float(seg) * 0.12, 1.0), 0.85, 1.0)
			else:
				glow_col = Color(0.35, 0.9, 1.0)
			node.draw_polyline(zig, Color(glow_col.r, glow_col.g, glow_col.b, 0.35 * k), 7.0)
			node.draw_polyline(zig, Color(glow_col.r, glow_col.g, glow_col.b, 0.95 * k), 2.5)
			node.draw_circle(b, 3.0 * k + 1.0, Color(1.0, 1.0, 1.0, 0.9 * k))

	# 怪物黑色词条：被强化的怪物描一圈暗紫光环（提示本局难度词条已生效）
	if AffixManager.active_monster.size() > 0:
		for e in enemies:
			if e.alive:
				node.draw_arc(e.pos, e.size + 3.0, 0, TAU, 24, Color(0.45, 0.12, 0.55, 0.5), 1.5)
	# 状态指示：灼烧（橙）/ 冰冻（青）
	for e in enemies:
		if e.alive and e.burn_t > 0.0:
			node.draw_arc(e.pos, e.size + 2.0, 0, TAU, 20, Color(1.0, 0.5, 0.15, 0.6), 1.5)
		if e.alive and e.freeze_t > 0.0:
			node.draw_arc(e.pos, e.size + 2.0, 0, TAU, 20, Color(0.4, 0.85, 1.0, 0.6), 1.5)
