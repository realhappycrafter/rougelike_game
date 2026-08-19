extends CharacterBody2D
## Player —— 玩家实体（GDD §3）
## 8 方向移动（WASD / 方向键），无冲刺；自动攻击由武器节点负责。
## 受伤/护甲/复活/升级三选一应用，全部数据驱动。
## 接触伤害由 EnemyManager 在更新时统一施加（调用 take_damage）。

const WeaponBaseScript = preload("res://scripts/entities/weapon_base.gd")
const CreatureVisual = preload("res://scripts/systems/creature_visual.gd")

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

var player_class = ""   # 当前职业 id（无职业时为 ""），决定三选一武器池与专属武器
var class_weapon = ""   # 当前职业专属武器 id（= 角色 start_weapon）

var body_radius = 14.0
var _face = Vector2(0, 1)   # 当前朝向（跟随移动方向，用于人物面部转向）
var luck = 0.0   # 幸运值（影响升级词条品质概率）

# ---- 动态模型字段（2026-08-19）：走路动画计时 / 攻击姿态计时 ----
var anim_t: float = 0.0       # 动画计时器（驱动双脚步态帧 + 身体起伏）
var attack_t: float = 0.0     # 攻击姿态计时（武器开火时置位，绘制挥击弧光）

var crit_chance = 0.0          # 暴击率（0..1）
var crit_dmg_bonus = 0.0       # 暴击伤害加成（叠加在基础 1.5 倍之上）
var lifesteal = 0.0            # 吸血比例（0..1，造成伤害按该比例回血）
var shield_pen = 0.0           # 护盾穿透（0..1，比例伤害无视敌人护盾直接打血）
var heal_mult = 1.0            # 治疗效率乘数（玩家质变 / 怪物黑词条削弱共用）

# ---- 联机字段 ----
var pid: int = -1              # 本玩家在房内的 pid（-1 表示未联机/单人）
var net_controlled: bool = false   # true：host 端代理玩家，由网络意图驱动，不读本地输入
var is_remote_render: bool = false # true：客机端本端化身，位置由快照预测/插值驱动，不本地移动
var net_color: Color = Color(0.45, 0.8, 1.0)  # 用于区分不同玩家的身份环颜色
var net_intent_move: Vector2 = Vector2.ZERO   # host 端：客机发来的移动意图

# 无头长时程测试用：命令行传入 --god 时置 true，使玩家免疫伤害、可覆盖 Boss/通关分支。
# 正常游玩与 Web 导出永不设置此字段，无任何副作用。
var god_mode: bool = false
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
	shield_pen = 0.0
	heal_mult = 1.0
	weapons = {}
	passives = {}
	player_class = str(c.get("class", ""))
	class_weapon = str(c.get("start_weapon", ""))
	queue_redraw()
	# 初始武器
	var wid = c.start_weapon
	if DataTables.weapons.has(wid):
		_equip_weapon(wid, 1)

## 应用局外强化（meta_upgrades）：在 setup_character 之后调用，
## 把存档中的多级属性加成叠加到基础值上（金币/经验乘数由 GameManager 单独处理）。
func apply_meta_upgrades(meta: Dictionary) -> void:
	if meta == null:
		return
	for id in DataTables.meta_upgrades.keys():
		var lvl = int(meta.get(id, 0))
		if lvl <= 0:
			continue
		var u = DataTables.meta_upgrades[id]
		# 职业专精：多属性加成（spec_per_level 字典），逐属性套用统一落点
		if u.has("class"):
			var spl = u.get("spec_per_level", {})
			for st in spl.keys():
				_apply_meta_stat(str(st), float(spl[st]) * float(lvl))
			continue
		var amt = float(u["per_level"]) * float(lvl)
		_apply_meta_stat(str(u["stat"]), amt)
	queue_redraw()

## 单个元属性加成落点（apply_meta_upgrades 与职业专精共用）。
## gold_gain / exp_gain 为全局乘算，由 GameManager 处理，此处跳过。
func _apply_meta_stat(stat: String, amt: float) -> void:
	match stat:
		"max_hp":
			base_max_hp += amt
			max_hp += amt
			hp += amt
		"damage":
			damage_bonus += amt
		"speed":
			base_speed += amt
			speed += amt
		"pickup":
			pickup_range += amt
		"cooldown":
			cooldown_reduction = min(0.5, cooldown_reduction + amt)
		"armor":
			armor += amt
		"luck":
			luck += amt
		"crit":
			crit_chance = min(1.0, crit_chance + amt)
		"crit_dmg":
			crit_dmg_bonus += amt
		"lifesteal":
			lifesteal = min(1.0, lifesteal + amt)
		"shield_pen":
			shield_pen = min(1.0, shield_pen + amt)
		"revives":
			revives += int(amt)

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
	anim_t += delta
	if attack_t > 0.0:
		attack_t = max(0.0, attack_t - delta)

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
	# 地面阴影（随体型放大）
	draw_circle(Vector2(0, r * 0.85), r * 0.95, Color(0, 0, 0, 0.30))
	# 动态模型：视觉放大 1.35x（命中判定仍用 body_radius）；移动时双脚步态帧交替 + 身体起伏
	var moving = velocity.length() > 10.0
	var frame = (1 if (moving and int(anim_t * 8.0) % 2 == 1) else 0)
	var bob = sin(anim_t * 16.0) * 1.5 if moving else 0.0
	var vs = r * 1.35
	var tex = CreatureVisual.get_player_texture(player_class, frame)
	draw_texture_rect(tex, Rect2(-vs, -vs + bob, vs * 2.0, vs * 2.0), false)
	# 攻击动画：武器开火瞬间朝朝向挥出半月弧光（随 attack_t 消散）
	if attack_t > 0.0:
		var k = attack_t / 0.22
		var arc_r = r * (2.4 + 0.7 * (1.0 - k))
		var ang = _face.angle()
		draw_arc(Vector2.ZERO, arc_r, ang - PI * 0.55, ang + PI * 0.55, 20,
			Color(1.0, 0.9, 0.5, 0.35 * k), 7.0)
		draw_arc(Vector2.ZERO, arc_r, ang - PI * 0.55, ang + PI * 0.55, 20,
			Color(1.0, 1.0, 1.0, 0.75 * k), 3.0)
	# 无敌表现：贴图白闪（替代白圆环），随动画闪烁提示无敌
	if invuln_time > 0:
		var blink = 0.3 + 0.3 * sin(anim_t * 26.0)
		draw_texture_rect(tex, Rect2(-vs, -vs + bob, vs * 2.0, vs * 2.0), false,
			Color(1.0, 1.0, 1.0, blink))
	# 联机身份环：用 net_color 区分不同玩家（单人默认蓝，不影响观感）
	if pid >= 0:
		draw_arc(Vector2.ZERO, r + 5.0, 0, TAU, 32, net_color, 2.0)

## 武器开火通知：置位攻击姿态计时（驱动挥击弧光动画）
func notify_attack() -> void:
	attack_t = 0.22

## 当前持有的减伤总和（盾卫等职业武器带 guard 字段，按等级线性增强）。
## 取所有已装备武器中 guard 之和，封顶 60%。
func effective_guard() -> float:
	var g = 0.0
	for wid in weapons.keys():
		var node = weapons[wid].node
		if node != null and node.data.has("guard"):
			var lvl = float(weapons[wid].level)
			g += float(node.data.guard) * (1.0 + 0.1 * (lvl - 1.0))
	return min(0.6, g)

func take_damage(amount: float) -> void:
	# 无头测试免伤钩子（仅命令行 --god 时启用，正常游玩恒为 false）
	if god_mode:
		return
	if invuln_time > 0:
		return
	var dmg = max(1.0, (amount - float(armor)) * (1.0 - effective_guard()))
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
			var wnode = weapons[opt.id].node
			if wnode != null and wnode.has_method("on_level_up"):
				wnode.on_level_up(weapons[opt.id].level)
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
	elif opt.type == "treasure":
		# 金币宝箱（满级兜底选项）：仅本端真实玩家计入全局金币，
		# 联机代理 / 客机渲染化身不算，避免重复加钱（host 权威，金币只加一次）
		if not net_controlled and not is_remote_render:
			var amt = int(opt.get("amount", 0))
			if amt > 0:
				GameManager.gold += amt
	elif opt.type == "stat":
		# 属性继续成长（满级兜底选项）：永久加成，仅本端真实玩家生效，
		# 联机代理 / 客机渲染化身不重复加（host 权威）。
		if not net_controlled and not is_remote_render:
			_apply_stat_buff(str(opt.get("stat", "")), float(opt.get("amount", 0.0)))
	elif opt.type == "affix":
		# 质变 / 超质变 词条：武器类登记到对应武器（特效由 AffixManager.weapon_mods 按需读取），
		# 玩家类再施加 pstat 效果到本玩家字段。仅本端真实玩家生效（host 权威）。
		if not net_controlled and not is_remote_render:
			var aid = str(opt.get("affix_id", ""))
			var cat = str(opt.get("category", ""))
			if cat == "player":
				if not AffixManager.active_player.has(aid):
					AffixManager.register_player_affix(aid)
					apply_player_affix(aid)
			else:
				var wid = str(opt.get("require_weapon", ""))
				if wid != "" and (not AffixManager.active_weapon.has(wid) or not AffixManager.active_weapon[wid].has(aid)):
					AffixManager.register_weapon_affix(wid, aid)

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
		"shield_pen":
			shield_pen = amt
	queue_redraw()

## 应用单个玩家类质变/超质变的 pstat 效果到本玩家字段。
## 设计为「注册时一次性施加」（非每次重算），避免与 meta/passive/stat-buff 叠加时重复计算；
## 武器类词条的特效走 AffixManager.weapon_mods 按需读取，此处不处理。
## 调用方需保证每个 aid 只施加一次（apply_upgrade / AffixManager.buy_affix 已去重）。
func apply_player_affix(aid: String) -> void:
	if not DataTables.mutations.has(aid):
		return
	var a = DataTables.mutations[aid]
	for e in a.get("effects", []):
		if str(e.get("kind", "")) != "pstat":
			continue
		var stat = str(e.get("stat", ""))
		var v = float(e.get("value", 0.0))
		match stat:
			"damage_mult":
				damage_bonus += v
			"speed_mult":
				base_speed *= (1.0 + v)
				speed = base_speed
			"max_hp_mult":
				var add = base_max_hp * v
				base_max_hp += add
				max_hp += add
				hp += add
			"luck_mult":
				luck *= (1.0 + v)
			"pickup_mult":
				pickup_range *= (1.0 + v)
			"heal_mult":
				heal_mult *= (1.0 + v)
			"gold_mult":
				GameManager.meta_gold_mult *= (1.0 + v)
			"crit_add":
				crit_chance = min(1.0, crit_chance + v)
			"lifesteal_add":
				lifesteal = min(1.0, lifesteal + v)
			"shield_pen_add":
				shield_pen = min(1.0, shield_pen + v)
			"cooldown_add":
				cooldown_reduction = min(0.5, cooldown_reduction + v)
	queue_redraw()

## 暴击倍率：基础 1.5 倍 + 暴伤加成
func effective_crit_mult() -> float:
	return 1.5 + crit_dmg_bonus

## 护盾穿透（0~1）：用于 EnemyManager.take_damage 的护盾机制
func get_shield_pen() -> float:
	return clamp(shield_pen, 0.0, 1.0)

## 属性继续成长（满级兜底三选一项）：直接、可无限叠加地永久增强玩家属性。
## ponytail：直接改动与 meta/passive 相同的字段；在「全部满级」兜底场景下安全，
## 因为此时不会再调用 _apply_passive 重算这些字段（passive 已 max，不会再次触发）。
func _apply_stat_buff(stat: String, amount: float) -> void:
	if amount == 0.0:
		return
	match stat:
		"max_hp":
			base_max_hp += amount
			max_hp += amount
			hp += amount
		"damage":
			damage_bonus += amount
		"speed":
			base_speed += amount
			speed += amount
		"pickup":
			pickup_range += amount
		"cooldown":
			cooldown_reduction = min(0.5, cooldown_reduction + amount)
		"armor":
			armor += amount
		"luck":
			luck += amount
		"crit":
			crit_chance = min(1.0, crit_chance + amount)
		"crit_dmg":
			crit_dmg_bonus += amount
		"lifesteal":
			lifesteal = min(1.0, lifesteal + amount)
		"shield_pen":
			shield_pen = min(1.0, shield_pen + amount)
	queue_redraw()

## 统一回血（吸血 / 治疗宝箱共用）；受 heal_mult（玩家质变 / 怪物黑词条削弱）影响
func heal(amount: float) -> void:
	if amount <= 0.0:
		return
	hp = min(max_hp, hp + amount * heal_mult)
	queue_redraw()

## 宝箱奖励：直接增加幸运（也登记为词条便于 UI 显示）
func add_luck(v: float) -> void:
	luck += v
	if not passives.has("luck"):
		passives["luck"] = {"level": 1, "quality": "white"}
	else:
		passives["luck"].level += 1
	queue_redraw()
