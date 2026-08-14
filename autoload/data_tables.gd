extends Node
## DataTables —— 全局 JSON 数据表加载与查询（GDD §11.1 / §11.4）
## 所有数值/内容均来自 data/*.json，代码不硬编码。

var weapons = {}
var passives = {}
var evolutions = {}
var enemies = {}
var waves = {}
var characters = {}
var difficulties = {}
var chests = {}
var maps = {}
var meta_upgrades = {}
var modes = {}
var shop_items = {}

func _ready():
	_load_all()

func _load_all():
	weapons = _load_json("res://data/weapons.json")
	passives = _load_json("res://data/passives.json")
	evolutions = _load_json("res://data/evolutions.json")
	enemies = _load_json("res://data/enemies.json")
	waves = _load_json("res://data/waves.json")
	characters = _load_json("res://data/characters.json")
	difficulties = _load_json("res://data/difficulties.json")
	chests = _load_json("res://data/chests.json")
	maps = _load_json("res://data/maps.json")
	meta_upgrades = _load_json("res://data/meta_upgrades.json")
	modes = _load_json("res://data/modes.json")
	shop_items = _load_json("res://data/shop_items.json")

func _load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("[DataTables] 找不到数据文件: " + path)
		return {}
	var f = FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("[DataTables] 无法打开: " + path)
		return {}
	var txt = f.get_as_text()
	f.close()
	var p = JSON.new()
	var err = p.parse(txt)
	if err != OK:
		push_error("[DataTables] JSON 解析失败 " + path + ": " + p.get_error_message())
		return {}
	return p.get_data()

## 便捷查询
func weapon(id: String) -> Dictionary: return weapons.get(id, {})
func passive(id: String) -> Dictionary: return passives.get(id, {})
func enemy(id: String) -> Dictionary: return enemies.get(id, {})
func character(id: String) -> Dictionary: return characters.get(id, {})
func map_data(id: String) -> Dictionary: return maps.get(id, {})
func meta_upgrade(id: String) -> Dictionary: return meta_upgrades.get(id, {})
