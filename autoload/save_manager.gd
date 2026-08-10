extends Node
## SaveManager —— 多存档槽位元进度（GDD §9 / §11.5 / 用户需求）
## 支持多个存档：每个存档（槽位）新建时选择难度，各自记录最佳时间与等级；
## 金币为全局元货币（跨槽位共享，用于后续解锁）。桌面端 user://，Web 端 IndexedDB。

const SAVE_PATH = "user://save.json"

var data = {
	"slots": {},        # id -> {difficulty, best_time, level, created}
	"active_slot": "",  # 当前选中的槽位
	"global_gold": 0,   # 全局元货币（解锁用）
	"settings": {"music_vol": 0.8, "sfx_vol": 0.8},
	"meta_upgrades": {},            # id -> 已购等级
	"map_progress": {"unlocked": ["zombie"], "cleared": []}  # 顺序解锁
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

## ---- 局外强化（元升级）----
## 价格公式：floor(cost_base * cost_growth^当前等级)
## 全部已购元升级（id -> 等级），供 player.apply_meta_upgrades 使用
func get_meta_upgrades() -> Dictionary:
	return data["meta_upgrades"]

func get_meta_level(id: String) -> int:
	if data["meta_upgrades"].has(id):
		return int(data["meta_upgrades"][id])
	return 0

func meta_upgrade_cost(id: String) -> int:
	if not DataTables.meta_upgrades.has(id):
		return 999999
	var u = DataTables.meta_upgrades[id]
	var lvl = get_meta_level(id)
	if lvl >= int(u["max_level"]):
		return -1  # 已满级
	return int(floor(float(u["cost_base"]) * pow(float(u["cost_growth"]), float(lvl))))

## 购买一级，成功返回 true（金币不足/满级返回 false）
func buy_meta_upgrade(id: String) -> bool:
	if not DataTables.meta_upgrades.has(id):
		return false
	var u = DataTables.meta_upgrades[id]
	var lvl = get_meta_level(id)
	if lvl >= int(u["max_level"]):
		return false
	var cost = meta_upgrade_cost(id)
	if int(data["global_gold"]) < cost:
		return false
	data["global_gold"] = int(data["global_gold"]) - cost
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

## 标记通关：加入 cleared，并解锁下一 order 的地图
func mark_map_cleared(id: String) -> void:
	if not data["map_progress"]["cleared"].has(id):
		data["map_progress"]["cleared"].append(id)
	if DataTables.maps.has(id):
		var next_order = int(DataTables.maps[id]["order"]) + 1
		for mid in DataTables.maps.keys():
			if int(DataTables.maps[mid]["order"]) == next_order:
				if not data["map_progress"]["unlocked"].has(mid):
					data["map_progress"]["unlocked"].append(mid)
				break
	save_data()

## 是否已通关
func is_map_cleared(id: String) -> bool:
	return data["map_progress"]["cleared"].has(id)

## ---- 设置 ----
func set_setting(key: String, value) -> void:
	data.settings[key] = value
	save_data()

func get_setting(key: String, default_value = null):
	if data.settings.has(key):
		return data.settings[key]
	return default_value
