extends Node
## SaveManager —— 多存档槽位元进度（GDD §9 / §11.5 / 用户需求）
## 支持多个存档：每个存档（槽位）新建时选择难度，各自记录最佳时间与等级；
## 金币为全局元货币（跨槽位共享，用于后续解锁）。桌面端 user://，Web 端 IndexedDB。

const SAVE_PATH = "user://save.json"

var data = {
	"slots": {},        # id -> {difficulty, best_time, level, created}
	"active_slot": "",  # 当前选中的槽位
	"global_gold": 0,   # 全局元货币（解锁/局外强化用）
	"global_emerald": 0, # 全局绿宝石（Boss 掉落积累，用于局外高级强化与局内高级道具）
	"settings": {"music_vol": 0.8, "sfx_vol": 0.8},
	"meta_upgrades": {},            # id -> 已购等级
	"map_progress": {"unlocked": ["zombie"], "cleared": []},  # 顺序解锁
	"short_cleared": []            # 短局通关记录：元素为 "worldId:stage"
}

func _ready():
	load_data()

func load_data() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var f = FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return
	var txt = f.get_as_text()
	f.close()
	var p = JSON.new()
	if p.parse(txt) != OK:
		push_error("[SaveManager] 存档解析失败，已忽略旧档")
		return
	var d = p.get_data()
	if typeof(d) == TYPE_DICTIONARY:
		data = d
	# 字段兜底
	if not data.has("slots"):
		data["slots"] = {}
	if not data.has("active_slot"):
		data["active_slot"] = ""
	if not data.has("global_gold"):
		data["global_gold"] = 0
	if not data.has("settings"):
		data["settings"] = {"music_vol": 0.8, "sfx_vol": 0.8}
	if not data.has("meta_upgrades"):
		data["meta_upgrades"] = {}
	if not data.has("global_emerald"):
		data["global_emerald"] = 0
	if not data.has("short_cleared"):
		data["short_cleared"] = []
	if not data.has("map_progress"):
		data["map_progress"] = {"unlocked": ["zombie"], "cleared": []}
	if not data["map_progress"].has("unlocked"):
		data["map_progress"]["unlocked"] = ["zombie"]
	if not data["map_progress"].has("cleared"):
		data["map_progress"]["cleared"] = []

func save_data() -> void:
	var f = FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		push_error("[SaveManager] 无法写入存档")
		return
	f.store_string(JSON.stringify(data))
	f.close()

## ---- 槽位管理 ----
func ensure_slot(id: String) -> void:
	if not data.slots.has(id):
		data.slots[id] = {
			"difficulty": "normal",
			"best_time": 0.0,
			"level": 1,
			"created": Time.get_unix_time_from_system()
		}
		save_data()

func create_slot(id: String, difficulty: String) -> void:
	data.slots[id] = {
		"difficulty": difficulty,
		"best_time": 0.0,
		"level": 1,
		"created": Time.get_unix_time_from_system()
	}
	data.active_slot = id
	save_data()

func delete_slot(id: String) -> void:
	if data.slots.has(id):
		data.slots.erase(id)
	if data.active_slot == id:
		data.active_slot = ""
		save_data()

func set_active(id: String) -> void:
	if data.slots.has(id):
		data.active_slot = id
		save_data()

## 当前选中的槽位 id（该字段存在 data 字典内，外部一律走此访问器）
func get_active_slot() -> String:
	return str(data["active_slot"])

func get_slot(id: String) -> Dictionary:
	if data.slots.has(id):
		return data.slots[id]
	return {}

func list_slots() -> Dictionary:
	return data.slots

func record_run(slot: String, time: float, level: int) -> void:
	if not data.slots.has(slot):
		return
	var s = data.slots[slot]
	if time > float(s.best_time):
		s.best_time = time
	if level > int(s.level):
		s.level = level
	save_data()

## ---- 元货币 ----
func add_gold(g: int) -> void:
	data["global_gold"] = int(data["global_gold"]) + int(g)
	save_data()

func get_gold() -> int:
	return int(data["global_gold"])

## ---- 绿宝石（Boss 掉落积累，局外/局内高级货币）----
func add_emerald(n: int) -> void:
	data["global_emerald"] = int(data["global_emerald"]) + int(n)
	save_data()

func get_emerald() -> int:
	return int(data["global_emerald"])

## ---- 局外强化（元升级）----
## 价格公式：floor(cost_base * cost_growth^当前等级)
## 全部已购元升级（id -> 等级），供 player.apply_meta_upgrades 使用
func get_meta_upgrades() -> Dictionary:
	return data["meta_upgrades"]

func get_meta_level(id: String) -> int:
	if data["meta_upgrades"].has(id):
		return int(data["meta_upgrades"][id])
	return 0

func meta_upgrade_currency(id: String) -> String:
	if not DataTables.meta_upgrades.has(id):
		return "gold"
	return str(DataTables.meta_upgrades[id].get("currency", "gold"))

func meta_upgrade_cost(id: String) -> int:
	# 仅返回金币价（兼容旧调用）；多币种请改用 meta_upgrade_cost_info
	var info = meta_upgrade_cost_info(id)
	return info.cost

## 返回 {cost, currency}；已满级 cost=-1
func meta_upgrade_cost_info(id: String) -> Dictionary:
	if not DataTables.meta_upgrades.has(id):
		return {"cost": 999999, "currency": "gold"}
	var u = DataTables.meta_upgrades[id]
	var lvl = get_meta_level(id)
	if lvl >= int(u["max_level"]):
		return {"cost": -1, "currency": meta_upgrade_currency(id)}
	var cost = int(floor(float(u["cost_base"]) * pow(float(u["cost_growth"]), float(lvl))))
	return {"cost": cost, "currency": meta_upgrade_currency(id)}

## 购买一级，成功返回 true（货币不足/满级返回 false）；按 currency 扣对应货币
func buy_meta_upgrade(id: String) -> bool:
	if not DataTables.meta_upgrades.has(id):
		return false
	var u = DataTables.meta_upgrades[id]
	var lvl = get_meta_level(id)
	if lvl >= int(u["max_level"]):
		return false
	var info = meta_upgrade_cost_info(id)
	var cost = info.cost
	var cur = info.currency
	var have = int(data["global_gold"]) if cur == "gold" else int(data["global_emerald"])
	if have < cost:
		return false
	if cur == "gold":
		data["global_gold"] = int(data["global_gold"]) - cost
	else:
		data["global_emerald"] = int(data["global_emerald"]) - cost
	data["meta_upgrades"][id] = lvl + 1
	save_data()
	return true

## ---- 地图进度（顺序解锁）----
func is_map_unlocked(id: String) -> bool:
	return data["map_progress"]["unlocked"].has(id)

func unlock_map(id: String) -> void:
	if not data["map_progress"]["unlocked"].has(id):
		data["map_progress"]["unlocked"].append(id)
		save_data()

## 标记长局通关：加入 cleared，并按「长局+短局」联合条件尝试解锁下一界
func mark_map_cleared(id: String) -> void:
	if not data["map_progress"]["cleared"].has(id):
		data["map_progress"]["cleared"].append(id)
		save_data()
	_maybe_unlock_next(id)

## 当某世界「长局已通关 且 短局 3 局全通」时解锁其下一 order 世界。
## 必须两条件同时满足，避免只通关其一就开下一界（短局单局通关=滥用解锁的回归点）。
func _maybe_unlock_next(world_id: String) -> void:
	if not DataTables.maps.has(world_id):
		return
	if not (is_map_cleared(world_id) and short_world_cleared(world_id)):
		return
	var next_order = int(DataTables.maps[world_id]["order"]) + 1
	for mid in DataTables.maps.keys():
		if int(DataTables.maps[mid]["order"]) == next_order:
			if not data["map_progress"]["unlocked"].has(mid):
				data["map_progress"]["unlocked"].append(mid)
				save_data()
			break

## 标记某个短局通关（去重），并据联合条件尝试解锁下一界
func mark_short_stage(world: String, stage: int) -> void:
	var k = _short_key(world, stage)
	if not data["short_cleared"].has(k):
		data["short_cleared"].append(k)
		save_data()
	_maybe_unlock_next(world)

## 是否已通关
func is_map_cleared(id: String) -> bool:
	return data["map_progress"]["cleared"].has(id)

## ---- 短局模式进度（诸天万界：每世界 3 个短局，全部通关解锁下一世界）----
func _short_key(world: String, stage: int) -> String:
	return str(world) + ":" + str(stage)

## 某世界是否解锁（短局模式）：与长局共用「map_progress.unlocked」门槛。
## 该列表仅在「长局通关 且 短局 3 局全通」时由 _maybe_unlock_next 填充，
## 因此短局与长局共用同一套解锁判定（需两者皆通关）。
func is_short_world_unlocked(world_id: String) -> bool:
	return is_map_unlocked(world_id)

## 某世界 3 个短局是否全部通关
func short_world_cleared(world_id: String) -> bool:
	for s in range(1, 4):
		if not data["short_cleared"].has(_short_key(world_id, s)):
			return false
	return true

## 下一个待打的短局（world,stage）；全部通关返回 {}（空字典）
func short_next() -> Dictionary:
	var ids = DataTables.maps.keys()
	ids.sort_custom(func(a, b): return int(DataTables.maps[a].get("order", 99)) < int(DataTables.maps[b].get("order", 99)))
	for mid in ids:
		if not is_short_world_unlocked(mid):
			continue
		for s in range(1, 4):
			if not data["short_cleared"].has(_short_key(mid, s)):
				return {"world": mid, "stage": s}
	return {}

## ---- 设置 ----
func set_setting(key: String, value) -> void:
	data.settings[key] = value
	save_data()

func get_setting(key: String, default_value = null):
	if data.settings.has(key):
		return data.settings[key]
	return default_value
