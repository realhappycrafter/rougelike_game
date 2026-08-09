extends CharacterBody2D
## Player —— 玩家实体（GDD §3）
## 8 方向移动（WASD / 方向键），无冲刺；自动攻击由武器节点负责。
## 受伤/护甲/复活/升级三选一应用，全部数据驱动。
## 接触伤害由 EnemyManager 在更新时统一施加（调用 take_damage）。

const WeaponBaseScript = preload("res://scripts/entities/weapon_base.gd")

var main = null

var base_max_hp = 100.0
var base_speed = 220.0
var max_hp = 100.0
var hp = 100.0
var armor = 0
var damage_bonus = 0.0       # 乘算加成（0.1 = +10%）
var cooldown_reduction = 0.0 # 0..0.5
var pickup_range = 40.0
var revives = 0
var invuln_time = 0.0

var speed = 220.0
var weapons = {}   # id -> {level, node}
var passives = {}  # id -> level

var body_radius = 14.0
var _face = Vector2(0, 1)   # 当前朝向（跟随移动方向，用于人物面部转向）
var luck = 0.0   # 幸运值（影响升级词条品质概率）

var crit_chance = 0.0          # 暴击率（0..1）
var crit_dmg_bonus = 0.0       # 暴击伤害加成（叠加在基础 1.5 倍之上）
var lifesteal = 0.0            # 吸血比例（0..1，造成伤害按该比例回血）

# ---- 联机字段 ----
var pid: int = -1              # 本玩家在房内的 pid（-1 表示未联机/单人）
var net_controlled: bool = false   # true：host 端代理玩家，由网络意图驱动，不读本地输入
var is_remote_render: bool = false # true：客机端本端化身，位置由快照预测/插值驱动，不本地移动
var net_color: Color = Color(0.45, 0.8, 1.0)  # 用于区分不同玩家的身份环颜色
var net_intent_move: Vector2 = Vector2.ZERO   # host 端：客机发来的移动意图
var net_intent_aim: Vector2 = Vector2.ZERO    # host 端：客机发来的瞄准方向
var downed: bool = false       # 是否处于倒地（MVP 中立即复活，仅作状态标记）

const QUALITY_ORDER = ["white", "green", "blue", "purple", "gold", "red"]
const QUALITY_MULT = {"white":1.0, "green":1.25, "blue":1.6, "purple":2.1, "gold":2.8, "red":4.0}

func _ready():
	var col = CollisionShape2D.new()
	col.shape = CircleShape2D.new()
	col.shape.radius = body_radius
	add_child(col)

func setup_character(c: Dictionary) -> void:
	base_max_hp = float(c.hp)
	max_hp = base_max_hp
	hp = max_hp
	base_speed = float(c.speed)
	speed = base_speed
	armor = 0
	damage_bonus = 0.0
	cooldown_reduction = 0.0
	pickup_range = 40.0
	revives = 0
	invuln_time = 0.0
	luck = 0.0
	crit_chance = 0.0
	crit_dmg_bonus = 0.0
	lifesteal = 0.0
	weapons = {}
	passives = {}
	queue_redraw()
	# 初始武器
	var wid = c.start_weapon
	if DataTables.weapons.has(wid):
		_equip_weapon(wid, 1)

func _equip_weapon(wid: String, lv: int) -> void:
	var w = Node2D.new()
	w.set_script(WeaponBaseScript)
	GameManager.world.add_child(w)
	w.setup(DataTables.weapons[wid], self, GameManager.world, main)
	w.on_level_up(lv)
	weapons[wid] = { "level": lv, "node": w }

func _physics_process(delta: float) -> void:
	if not GameManager.playing:
		return
	if invuln_time > 0:
		invuln_time -= delta

	# host 端代理玩家：仅由网络意图驱动，忽略本地键盘/摇杆
	if net_controlled:
		var v = net_intent_move
		if v.length() > 0.0:
			v = v.normalized() * speed
			if net_intent_aim.length() > 0.0:
				_face = net_intent_aim.normalized()
			else:
				_face = v.normalized()
		velocity = v
		move_and_slide()
		queue_redraw()
		return

	# 客机端本端化身：位置每帧由 main 的客户端预测/插值在 _client_tick 中设置，这里只重绘
	if is_remote_render:
		queue_redraw()
		return

	var v = Vector2.ZERO
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):   v.y -= 1
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN): v.y += 1
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT): v.x -= 1
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):v.x += 1
	# 触屏虚拟摇杆（仅移动端激活，见 TouchInput autoload；桌面返回 ZERO，无影响）
	if TouchInput.active:
		v += TouchInput.get_move_vector()
	if v.length() > 0:
		if v.length() > 1.0:
			v = v.normalized()   # 键盘+摇杆同向叠加超过 1 时归一，避免超速
		v = v * speed
		_face = v.normalized()
		velocity = v
	move_and_slide()
	queue_redraw()   # 玩家单实例，每帧重绘成本可忽略；让面部朝向实时跟随移动

func _draw():
	var r = body_radius
	var fcx = _face.x * r * 0.18
	var fcy = -r * 0.22
	# 地面阴影
	draw_circle(Vector2(0, r * 0.75), r * 0.85, Color(0, 0, 0, 0.30))
	# 披风/身体（深色）
	draw_circle(Vector2.ZERO, r, Color(0.16, 0.14, 0.22, 1.0))
	# 兜帽（稍亮）
	draw_circle(Vector2(_face.x * r * 0.08, -r * 0.28), r * 0.72, Color(0.30, 0.25, 0.40, 1.0))
	# 面部发光区（朝向偏移）
	draw_circle(Vector2(fcx, fcy), r * 0.42, Color(0.92, 0.85, 0.65, 1.0))
	# 双眼（红）
	draw_circle(Vector2(fcx - r * 0.20, fcy), 2.3, Color(0.95, 0.20, 0.20, 1.0))
	draw_circle(Vector2(fcx + r * 0.20, fcy), 2.3, Color(0.95, 0.20, 0.20, 1.0))
	# 描边
	draw_arc(Vector2.ZERO, r, 0, TAU, 32, Color(0.60, 0.50, 0.72, 1.0), 2.0)
	if invuln_time > 0:
		draw_circle(Vector2.ZERO, r + 3.0, Color(1, 1, 1, 0.4))
	# 联机身份环：用 net_color 区分不同玩家（单人默认蓝，不影响观感）
	if pid >= 0:
		draw_arc(Vector2.ZERO, r + 5.0, 0, TAU, 32, net_color, 2.0)

func take_damage(amount: float) -> void:
	if invuln_time > 0:
		return
	var dmg = max(1.0, amount - float(armor))
	hp -= dmg
	invuln_time = 0.5
	queue_redraw()
	if hp <= 0:
		hp = 0
		if revives > 0:
			revives -= 1
			hp = max_hp
			invuln_time = 5.0
			if main and main.has_method("clear_enemies"):
				main.clear_enemies()
		else:
			# host 端代理玩家倒地：交给 main 复活（不影响整局），不触发全局结算
			if net_controlled and main and main.has_method("on_remote_death"):
				main.on_remote_death(self)
			elif main and main.has_method("on_player_death"):
				main.on_player_death()

## host 端：设置来自客机的网络意图（移动 + 瞄准方向）
func set_net_intent(move: Vector2, aim: Vector2) -> void:
	net_intent_move = move
	net_intent_aim = aim

## 应用三选一结果（GDD §6.2）
func apply_upgrade(opt: Dictionary) -> void:
	if opt.type == "weapon":
		if weapons.has(opt.id):
			weapons[opt.id].level += 1
			weapons[opt.id].node.on_level_up(weapons[opt.id].level)
		else:
			_equip_weapon(opt.id, 1)
	elif opt.type == "passive":
		var q = "white"
		if opt.has("quality") and opt.quality != null:
			q = opt.quality
		if passives.has(opt.id):
			passives[opt.id].level += 1
			var old_i = QUALITY_ORDER.find(passives[opt.id].quality)
			var new_i = QUALITY_ORDER.find(q)
			if new_i > old_i:
				passives[opt.id].quality = q
		else:
			passives[opt.id] = {"level": 1, "quality": q}
		_apply_passive(opt.id)

func _apply_passive(id: String) -> void:
	var p = DataTables.passives[id]
	var lv = passives[id].level
	var q = passives[id].quality
	var qmult = QUALITY_MULT.get(q, 1.0)
	var amt = float(p.per_level) * float(lv) * qmult
	match p.stat:
		"armor":
			armor = amt
		"max_hp":
			var before = max_hp
			max_hp = base_max_hp + amt
			hp += (max_hp - before)
		"cooldown":
			cooldown_reduction = min(0.5, amt)
		"pickup":
			pickup_range = 40.0 + amt
		"damage":
			damage_bonus = amt
		"speed":
			speed = base_speed + amt
		"luck":
			luck = amt
		"crit":
			crit_chance = amt
		"crit_damage":
			crit_dmg_bonus = amt
		"lifesteal":
			lifesteal = amt
	queue_redraw()

## 暴击倍率：基础 1.5 倍 + 暴伤加成
func effective_crit_mult() -> float:
	return 1.5 + crit_dmg_bonus

## 统一回血（吸血 / 治疗宝箱共用）
func heal(amount: float) -> void:
	if amount <= 0.0:
		return
	hp = min(max_hp, hp + amount)
	queue_redraw()

## 宝箱奖励：直接增加幸运（也登记为词条便于 UI 显示）
func add_luck(v: float) -> void:
	luck += v
	if not passives.has("luck"):
		passives["luck"] = {"level": 1, "quality": "white"}
	else:
		passives["luck"].level += 1
	queue_redraw()
