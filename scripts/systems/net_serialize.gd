extends Node
## NetSerialize —— 联机快照（state）序列化纯函数集合（零成本方案：host 权威 → 客机渲染）
## 全部为 static：不依赖场景树，便于 tests/smoke_check 直接单元测试，无头即可验证协议字段。
## 协议字段约定（与 net_manager.gd / main.gd / remote_world.gd 配套）：
##   state 顶层：t=state, rt=运行秒, kills=击杀, g=金币, lv=等级, exp=经验, enn=升级所需经验,
##                players=玩家数组, enemies=敌人紧凑数组, gems=宝石数组, chests=宝箱数组
##   玩家条目：pid / x / y / fx / fy / hp / mhp / lv / wp(武器) / c(颜色) / down
##   宝石条目：x / y / ty(类型)
##   宝箱条目：x / y / q(品质 0..5)

## 序列化单个玩家（真实 player 节点或满足属性接口的 dict 均可，便于单测）
static func serialize_player(p) -> Dictionary:
	var wp = []
	if p.weapons is Dictionary:
		for wid in p.weapons.keys():
			var w = p.weapons[wid]
			var ev = 0
			if w.node != null and w.node.evolved:
				ev = 1
			wp.append({"id": wid, "level": int(w.level), "ev": ev})
	var col = p.net_color if (p.net_color is Color) else Color(0.45, 0.8, 1.0)
	return {
		"pid": int(p.pid),
		"x": round(p.global_position.x * 10.0) / 10.0,
		"y": round(p.global_position.y * 10.0) / 10.0,
		"fx": round(p._face.x * 100.0) / 100.0,
		"fy": round(p._face.y * 100.0) / 100.0,
		"hp": round(p.hp),
		"mhp": round(p.max_hp),
		"lv": int(GameManager.level),
		"wp": wp,
		"c": [col.r, col.g, col.b],
		"down": 1 if p.downed else 0
	}

## 序列化单个宝石掉落（真实 gem 节点或满足接口的 dict 均可）
static func serialize_gem(g) -> Dictionary:
	return {
		"x": round(g.global_position.x * 10.0) / 10.0,
		"y": round(g.global_position.y * 10.0) / 10.0,
		"ty": str(g.type)
	}

## 序列化单个宝箱掉落（真实 chest 节点或满足接口的 dict 均可）
static func serialize_chest(c) -> Dictionary:
	return {
		"x": round(c.global_position.x * 10.0) / 10.0,
		"y": round(c.global_position.y * 10.0) / 10.0,
		"q": int(c.quality)
	}

## 组装完整世界快照（各数组应已通过上面的 serialize_* 序列化好）
static func build_snapshot(players: Array, enemies: Array, gems: Array, chests: Array,
		run_time: float, kills: int, gold: int, level: int, exp: int, exp_needed: int) -> Dictionary:
	return {
		"t": "state",
		"rt": run_time,
		"kills": kills,
		"g": gold,
		"lv": level,
		"exp": exp,
		"enn": exp_needed,
		"players": players,
		"enemies": enemies,
		"gems": gems,
		"chests": chests
	}
