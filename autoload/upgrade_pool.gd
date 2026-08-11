extends Node
## UpgradePool —— 三选一选项池（GDD §6.2 / 用户需求：词条品质 + 幸运）
## 武器选项保持无品质；被动/词条选项带品质（白绿蓝紫金红），
## 品质倍率影响数值，幸运值越高越容易出高品质。Boss 奖励强制一个红色词条。

const QUALITY = [
	{"id":"white",  "name":"白", "color":"#d8d8d8", "mult":1.0,  "base":50.0},
	{"id":"green",  "name":"绿", "color":"#3ddc6b", "mult":1.25, "base":30.0},
	{"id":"blue",   "name":"蓝", "color":"#3aa0ff", "mult":1.6,  "base":14.0},
	{"id":"purple", "name":"紫", "color":"#b060ff", "mult":2.1,  "base":5.0},
	{"id":"gold",   "name":"金", "color":"#ffcc33", "mult":2.8,  "base":1.5},
	{"id":"red",    "name":"红", "color":"#ff4040", "mult":4.0,  "base":0.3}
]

func quality_mult(id: String) -> float:
	for q in QUALITY:
		if q.id == id:
			return q.mult
	return 1.0

func quality_color(id: String) -> String:
	for q in QUALITY:
		if q.id == id:
			return q.color
	return "#ffffff"

## 幸运值越高，权重越偏向高品质（更高 index）
func roll_quality(luck: float) -> Dictionary:
	var luck_units = clamp(luck / 5.0, 0.0, 8.0)
	var growth = 1.15
	var weights = []
	var total = 0.0
	for i in range(QUALITY.size()):
		var w = QUALITY[i].base * pow(growth, i * luck_units)
		weights.append(w)
		total += w
	randomize()
	var r = randf() * total
	var acc = 0.0
	for i in range(QUALITY.size()):
		acc += weights[i]
		if r <= acc:
			return QUALITY[i]
	return QUALITY[0]

## 按品质倍率生成被动词条的实际加成描述（修复「不同品质显示数值一样」）
func _passive_desc(p: Dictionary, qmult: float) -> String:
	var v = float(p.per_level) * qmult
	match p.stat:
		"armor":    return "护甲 +%d（每点减伤1）" % int(v)
		"max_hp":   return "最大生命 +%d" % int(v)
		"cooldown": return "冷却缩减 +%d%%（上限50%%）" % int(v * 100)
		"pickup":   return "拾取范围 +%d" % int(v)
		"damage":   return "伤害 +%d%%" % int(v * 100)
		"speed":    return "移动速度 +%d" % int(v)
		"luck":     return "幸运 +%d" % int(v)
		"crit":     return "暴击率 +%d%%" % int(v * 100)
		"crit_damage": return "暴击伤害 +%d%%" % int(v * 100)
		"lifesteal": return "吸血 +%d%%" % int(v * 100)
	return p.desc

func generate(player) -> Array:
	var opts = []
	var held_weapons = player.weapons.keys()
	var held_passives = player.passives  # id -> {level, quality}

	# 武器选项（无品质）
	for wid in DataTables.weapons.keys():
		# 按地图过滤：maps 为空=全图可用；非空=仅含当前 map_id 时可用
		var wdata = DataTables.weapons[wid]
		var maps_allowed = wdata.get("maps", [])
		if maps_allowed.size() > 0 and not maps_allowed.has(GameManager.map_id):
			continue
		if held_weapons.has(wid):
			var lv = player.weapons[wid].level
			if lv < DataTables.weapons[wid].max_level:
				var next_lv = lv + 1
				var extra = ""
				if wdata.has("level_desc") and (next_lv - 2) >= 0 and (next_lv - 2) < wdata.level_desc.size():
					extra = "\n" + wdata.level_desc[next_lv - 2]
				opts.append({
					"type": "weapon", "id": wid,
					"name": wdata.name,
					"desc": "升级 " + wdata.name + " → Lv" + str(next_lv) + extra,
					"weight": 2, "quality": null, "quality_color": null
				})
		else:
			opts.append({
				"type": "weapon", "id": wid,
				"name": DataTables.weapons[wid].name,
				"desc": "新武器：" + DataTables.weapons[wid].name,
				"weight": 3, "quality": null, "quality_color": null
			})

	# 词条（被动）选项：带品质，受幸运影响；移速词条出现概率降低
	for pid in DataTables.passives.keys():
		var maxlv = int(DataTables.passives[pid].max_level)
		var cur_lv = 0
		if held_passives.has(pid):
			cur_lv = int(held_passives[pid].level)
		if cur_lv < maxlv:
			var q = roll_quality(player.luck)
			var p = DataTables.passives[pid]
			var pw = 1.0
			if pid == "speed":
				pw = 0.4   # 移速词条不常出现（用户需求：降低出现概率）
			opts.append({
				"type": "passive", "id": pid,
				"name": p.name + "（" + q.name + "）",
				"desc": _passive_desc(p, q.mult),
				"weight": pw, "quality": q.id, "quality_color": q.color
			})

	# 加权随机抽 3（不重复）
	randomize()
	var chosen = []
	var pool = opts.duplicate()
	while chosen.size() < 3 and pool.size() > 0:
		var total = 0
		for o in pool:
			total += o.weight
		var r = randf() * total
		var acc = 0.0
		var idx = 0
		for i in range(pool.size()):
			acc += pool[i].weight
			if r <= acc:
				idx = i
				break
		chosen.append(pool[idx])
		pool.remove_at(idx)

	# Boss 奖励：保证 3 选 1 中包含一个红色品质词条
	if GameManager.red_reward_queued:
		GameManager.red_reward_queued = false
		var avail = []
		for pid in DataTables.passives.keys():
			var maxlv = int(DataTables.passives[pid].max_level)
			var cur_lv = 0
			if player.passives.has(pid):
				cur_lv = int(player.passives[pid].level)
			if cur_lv < maxlv:
				avail.append(pid)
		if avail.size() > 0:
			var pid = avail[randi() % avail.size()]
			var forced = {
				"type": "passive", "id": pid,
				"name": DataTables.passives[pid].name + "（红）",
				"desc": DataTables.passives[pid].desc + " [红色品质·Boss奖励]",
				"weight": 0, "quality": "red",
				"quality_color": quality_color("red"), "forced_red": true
			}
			var replaced = false
			for i in range(chosen.size()):
				if chosen[i].type == "passive":
					chosen[i] = forced
					replaced = true
					break
			if not replaced:
				chosen.append(forced)
				if chosen.size() > 3:
					chosen = chosen.slice(chosen.size() - 3, chosen.size())

	# 选项不足 3 个（武器/被动全部满级时常见）：用「属性继续成长」+「金币宝箱」
	# 混合兜底补齐到 3 个，保证升级始终有三选一，且两类都出现
	# （修复「满级后无三选一」的 bug，并按需求让满级后仍有成长与金币可选）。
	if chosen.size() < 3:
		var growth = _fallback_growth()
		var treasures = _fallback_treasures()
		randomize()
		growth.shuffle()
		treasures.shuffle()
		# 组装顺序：先放一个「属性成长」、再放一个「金币」，保证两类都出现；
		# 剩余槽位优先继续补「属性成长」，让满级后仍以成长为主、金币为辅。
		var seq = []
		var gi = 0
		var ti = 0
		if growth.size() > 0:
			seq.append(growth[gi]); gi += 1
		if treasures.size() > 0:
			seq.append(treasures[ti]); ti += 1
		while seq.size() < 3:
			if gi < growth.size():
				seq.append(growth[gi]); gi += 1
			elif ti < treasures.size():
				seq.append(treasures[ti]); ti += 1
			else:
				break
		for s in seq:
			if chosen.size() >= 3:
				break
			chosen.append(s)

	# 去掉内部 weight 字段，避免 UI 显示
	for c in chosen:
		c.erase("weight")
	return chosen

## 全部升级满级后的兜底选项：属性继续成长（永久加成，可无限叠加）
func _fallback_growth() -> Array:
	return [
		{"type":"stat","stat":"max_hp","amount":25.0,"name":"属性成长·生命","desc":"最大生命 +25（持续成长）","weight":0,"quality":null,"quality_color":null},
		{"type":"stat","stat":"damage","amount":0.08,"name":"属性成长·伤害","desc":"伤害 +8%（持续成长）","weight":0,"quality":null,"quality_color":null},
		{"type":"stat","stat":"speed","amount":15.0,"name":"属性成长·移速","desc":"移动速度 +15（持续成长）","weight":0,"quality":null,"quality_color":null},
		{"type":"stat","stat":"pickup","amount":20.0,"name":"属性成长·拾取","desc":"拾取范围 +20（持续成长）","weight":0,"quality":null,"quality_color":null},
		{"type":"stat","stat":"cooldown","amount":0.03,"name":"属性成长·冷却","desc":"冷却缩减 +3%（持续成长）","weight":0,"quality":null,"quality_color":null},
		{"type":"stat","stat":"armor","amount":1.0,"name":"属性成长·护甲","desc":"护甲 +1（持续成长）","weight":0,"quality":null,"quality_color":null},
		{"type":"stat","stat":"luck","amount":1.0,"name":"属性成长·幸运","desc":"幸运 +1（持续成长）","weight":0,"quality":null,"quality_color":null},
		{"type":"stat","stat":"crit","amount":0.03,"name":"属性成长·暴击","desc":"暴击率 +3%（持续成长）","weight":0,"quality":null,"quality_color":null},
		{"type":"stat","stat":"crit_dmg","amount":0.08,"name":"属性成长·暴伤","desc":"暴击伤害 +8%（持续成长）","weight":0,"quality":null,"quality_color":null},
		{"type":"stat","stat":"lifesteal","amount":0.03,"name":"属性成长·吸血","desc":"吸血 +3%（持续成长）","weight":0,"quality":null,"quality_color":null}
	]

## 全部升级满级后的兜底选项：三档金币宝箱，保证升级始终有三选一
func _fallback_treasures() -> Array:
	return [
		{"type":"treasure","id":"gold_s","name":"金币宝箱（小）","desc":"立即获得 60 金币","weight":0,"quality":null,"quality_color":null,"amount":60},
		{"type":"treasure","id":"gold_m","name":"金币宝箱（中）","desc":"立即获得 180 金币","weight":0,"quality":null,"quality_color":null,"amount":180},
		{"type":"treasure","id":"gold_l","name":"金币宝箱（大）","desc":"立即获得 450 金币","weight":0,"quality":null,"quality_color":null,"amount":450}
	]
