extends Node
## ShopManager —— 局内强化商店（需求 #2）
## 商品来自 data/shop_items.json，分三类：消耗品(一次性道具) / 武器升级 / 属性提升。
## 用局内金币或绿宝石购买；购买效果只作用于当前这一局（不持久化、不带入局外）。
## 绿宝石为局内运行包（GameManager.emerald），局末结算时存入全局绿宝石。

var items: Dictionary = {}

func _ready() -> void:
	items = DataTables.shop_items

## 购买一件商品：扣费 + 应用效果。成功返回 true（货币不足 / 无法应用则 false 且不扣费）
func buy(item_id: String, player) -> bool:
	if player == null:
		return false
	if not items.has(item_id):
		return false
	var it = items[item_id]
	var cur = str(it.get("currency", "gold"))
	var cost = int(it.cost)
	var have = GameManager.gold if cur == "gold" else GameManager.emerald
	if have < cost:
		return false
	if not _apply_effect(it.get("effect", {}), player):
		return false   # 效果无法应用（如已无新武器），不扣费
	if cur == "gold":
		GameManager.gold -= cost
	else:
		GameManager.emerald -= cost
	GameManager.emit_signal("hud_changed")
	return true

func can_afford(item_id: String) -> bool:
	if not items.has(item_id):
		return false
	var it = items[item_id]
	var cur = str(it.get("currency", "gold"))
	var have = GameManager.gold if cur == "gold" else GameManager.emerald
	return have >= int(it.cost)

func _apply_effect(eff: Dictionary, player) -> bool:
	var t = eff.get("type", "")
	match t:
		"heal_full":
			player.hp = player.max_hp
			return true
		"aoe_damage":
			var amt = float(eff.get("amount", 1000))
			var uids = []
			for en in EnemyManager.enemies:
				if en.alive:
					uids.append(en.uid)
			for uid in uids:
				EnemyManager.take_damage(uid, amt, Vector2.ZERO, 0.0, player)
			return true
		"gold":
			GameManager.gold += int(eff.get("amount", 0))
			return true
		"exp":
			var frac = float(eff.get("amount", 0.5))
			GameManager.add_exp(int(GameManager.exp_needed * frac))
			return true
		"weapon_level":
			return _weapon_level(int(eff.get("levels", 1)), player)
		"new_weapon":
			return _new_weapon(player)
		"stat":
			var stat = str(eff.get("stat", ""))
			var amt = float(eff.get("amount", 0.0))
			# 与升级三选一一致：同时作用于本人与所有联机代理（host 权威）
			for p in GameManager.combat_players:
				if is_instance_valid(p):
					p._apply_stat_buff(stat, amt)
			return true
	return false

## 随机一把已有武器 +levels 级；若尚未拥有任何武器则退化为「获得新武器」
func _weapon_level(levels: int, player) -> bool:
	var owned = player.weapons.keys()
	if owned.is_empty():
		return _new_weapon(player)
	var wid = owned[randi() % owned.size()]
	for i in range(levels):
		player.apply_upgrade({"type": "weapon", "id": wid})
	return true

## 获得一把随机尚未拥有的武器；若已全部拥有则不扣费（返回 false）
func _new_weapon(player) -> bool:
	var candidates = []
	for wid in DataTables.weapons.keys():
		if not player.weapons.has(wid):
			candidates.append(wid)
	if candidates.is_empty():
		return false
	var wid = candidates[randi() % candidates.size()]
	player.apply_upgrade({"type": "weapon", "id": wid})
	return true
