extends Node2D
## Chest —— 地图奖励点 + 宝箱品质系统（用户需求：品质箱子）
## 箱子有 6 档品质（白/绿/蓝/紫/金/红），奖励也分 6 档等级。
## 奖励等级由箱子品质决定概率分布：
##   红箱 100% 红奖、金箱 10% 红奖、紫箱 1%…（每降一档 ÷10，即「以此类推」）
##   非红部分以箱子「主体色」对应等级为最高概率（绿箱主要给绿奖、蓝箱主要给蓝奖…）
##   幸运属性提升高等级 / 红奖概率。
## 红色奖励附带额外金币（极品）。

# 品质等级：0=白 1=绿 2=蓝 3=紫 4=金 5=红
const QUALITY_NAMES = ["白", "绿", "蓝", "紫", "金", "红"]
const QUALITY_HTML  = ["#e8e8e8", "#4caf50", "#2196f3", "#9c27b0", "#ffc107", "#f44336"]
const LIFETIME = 30.0   # 宝箱存在时间（秒），到点自动过期消失
# 红奖基础概率（按箱品质）：红1.0 金0.1 紫0.01 蓝0.001 绿0.0001 白0.00001（每降一档 ÷10）
const RED_CHANCE = [0.00001, 0.0001, 0.001, 0.01, 0.1, 1.0]
# 奖励等级数值倍率（白→红）。整体偏低，且红明确高于金（用户要求）
const LEVEL_MULT = [1.0, 1.3, 1.6, 2.0, 2.5, 3.5]

var reward_id = "levelup"
var data = {}
var main = null
var taken = false
var quality: int = 0
var life: float = 30.0    # 剩余存在时间（秒）
var QUALITY_COLORS = []

func _ready() -> void:
	QUALITY_COLORS = []
	for h in QUALITY_HTML:
		QUALITY_COLORS.append(Color.from_string(h, Color.WHITE))

func spawn(pos: Vector2, rid: String, main_ref, q: int = 0) -> void:
	global_position = pos
	reward_id = rid
	if DataTables.chests.has(rid):
		data = DataTables.chests[rid]
	quality = clamp(q, 0, QUALITY_NAMES.size() - 1)
	main = main_ref
	taken = false
	life = LIFETIME
	visible = true

func _process(delta: float) -> void:
	if taken:
		return
	if GameManager.player == null or not GameManager.playing:
		return
	life -= delta
	if life <= 0.0:
		_expire()
		return
	if global_position.distance_to(GameManager.player.global_position) < (GameManager.player.body_radius + 24.0):
		_grant()
		taken = true
		if main != null and "active_chests" in main:
			main.active_chests.erase(self)
		queue_free()

## 按箱子品质 roll 出奖励等级（0=白 … 5=红）
func roll_reward_level(q: int, luck: float) -> int:
	var lf = 1.0 + luck * 0.05     # 幸运加成：偏向高等级 / 红奖
	var p_red = RED_CHANCE[q]
	if q < 5:
		p_red = min(0.99, p_red * lf)
	else:
		p_red = 1.0                 # 红箱 100% 红奖
	if randf() < p_red:
		return 5
	# 非红部分：在 0..q 按权重分布，主体色等级(q)最高，幸运再向高等级偏移
	var weights = []
	var sum = 0.0
	for L in range(q + 1):
		var w = pow(0.4, q - L) * pow(lf, L)
		weights.append(w)
		sum += w
	var r = randf() * sum
	for L in range(q + 1):
		r -= weights[L]
		if r <= 0.0:
			return L
	return 0

func _grant() -> void:
	if data.is_empty():
		return
	var luck = 0.0
	if GameManager.player != null:
		luck = GameManager.player.luck
	var lvl = roll_reward_level(quality, luck)
	var mult = LEVEL_MULT[lvl]
	var q = QUALITY_NAMES[lvl]
	var desc = ""
	match data.reward:
		"levelup":
			# 经验宝箱按品质给当前等级所需经验的固定比例（红=直接升级）
			var frac = [0.05, 0.10, 0.20, 0.40, 0.70, 1.0][lvl]
			if lvl >= 5:
				GameManager.add_exp(GameManager.exp_needed)
				desc = "红·经验（直接升级）"
			else:
				GameManager.add_exp(int(GameManager.exp_needed * frac))
				desc = q + "·经验 +" + str(int(frac * 100)) + "%"
		"speed":
			var v = int(data.value * mult)
			GameManager.player.base_speed += float(v)
			GameManager.player.speed = GameManager.player.base_speed
			desc = q + "·移速 +" + str(v)
		"maxhp":
			var v = int(data.value * mult)
			GameManager.player.base_max_hp += float(v)
			GameManager.player.max_hp += float(v)
			GameManager.player.hp += float(v)
			desc = q + "·生命上限 +" + str(v)
		"luck":
			var v = int(data.value * mult)
			GameManager.player.add_luck(float(v))
			desc = q + "·幸运 +" + str(v)
		"damage":
			var v = float(data.value) * mult
			GameManager.player.damage_bonus += v
			desc = q + "·伤害 +" + str(int(v * 100)) + "%"
		"gold":
			var v = int(data.value * mult)
			GameManager.gold += v
			desc = q + "·金币 +" + str(v)
		# 职业专属武器强化（class_weapon）已移出宝箱：专属武器只在商店与升级三选一出现，
		# 避免宝箱把其他/本职业专属武器塞给玩家（用户需求）。
		# 红色奖励额外给一笔金币（极品保底）
	if lvl == 5:
		GameManager.gold += 100
		desc += " +金币100"
	if main != null and main.has_method("on_chest_opened"):
		var qcol = QUALITY_COLORS[lvl] if lvl < QUALITY_COLORS.size() else Color.GOLD
		main.on_chest_opened(desc, qcol)

func _expire() -> void:
	taken = true
	if main != null and "active_chests" in main:
		main.active_chests.erase(self)
	queue_free()

func _draw() -> void:
	if taken:
		return
	var qcol = QUALITY_COLORS[quality] if quality < QUALITY_COLORS.size() else Color.GOLD
	draw_rect(Rect2(-18, -16, 36, 32), qcol)
	draw_rect(Rect2(-18, -16, 36, 32), Color(0.12, 0.10, 0.04, 0.9), false, 3.0)
	# 内部高光，提示可拾取
	draw_rect(Rect2(-9, -7, 18, 14), Color(1.0, 1.0, 1.0, 0.5))
