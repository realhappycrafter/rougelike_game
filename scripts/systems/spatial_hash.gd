class_name SpatialHash
extends RefCounted
## 均匀网格空间哈希（GDD §11.3 性能优化）
## 用于敌人分离斥力、弹道/光环/环绕命中、玩家接触伤害的邻居查询。
## 替代 800 个 Area2D 的物理 broadphase，在 Web 单线程下把 ~O(n^2) 降到近似 O(n)。

var cell_size: float = 64.0
var cells: Dictionary = {}   # Vector2i -> Array[uid]

func _init(p_cell_size: float = 64.0) -> void:
	cell_size = max(1.0, p_cell_size)

func _key(pos: Vector2) -> Vector2i:
	return Vector2i(floor(pos.x / cell_size), floor(pos.y / cell_size))

func insert(id, pos: Vector2) -> void:
	var k = _key(pos)
	if not cells.has(k):
		cells[k] = []
	cells[k].append(id)

func remove(id, pos: Vector2) -> void:
	var k = _key(pos)
	if not cells.has(k):
		return
	var arr = cells[k]
	var i = arr.find(id)
	if i >= 0:
		arr.remove_at(i)
	if arr.is_empty():
		cells.erase(k)

## 物体移动后更新其所在格子（同格则跳过）
func update(id, old_pos: Vector2, new_pos: Vector2) -> void:
	var ok = _key(old_pos)
	var nk = _key(new_pos)
	if ok == nk:
		return
	remove(id, old_pos)
	insert(id, new_pos)

## 返回半径内所有可能碰撞的 id（粗筛，调用方需做精确距离判定）
func query_radius(pos: Vector2, radius: float) -> Array:
	var out: Array = []
	var r = max(0.0, radius)
	var minx = int(floor((pos.x - r) / cell_size))
	var maxx = int(floor((pos.x + r) / cell_size))
	var miny = int(floor((pos.y - r) / cell_size))
	var maxy = int(floor((pos.y + r) / cell_size))
	for x in range(minx, maxx + 1):
		for y in range(miny, maxy + 1):
			var k = Vector2i(x, y)
			if cells.has(k):
				for id in cells[k]:
					out.append(id)
	return out
