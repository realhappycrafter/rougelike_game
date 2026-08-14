extends Control
## Menu —— 开始界面（GDD §12.4 / 用户需求：开始/设置/存档管理）
## 多存档槽位：每个新存档选难度；全局金币跨槽共享。
## 文字字号与布局位置均按视口宽度等比缩放，并在窗口尺寸变化时自动重排。

const DecorBgScript = preload("res://scripts/systems/decor_bg.gd")

var bg: Control
var title: Label
var main_buttons = []
var slot_panel: Panel
var difficulty_panel: Panel
var settings_panel: Panel
var saves_panel: Panel
var map_panel: Panel
var meta_panel: Panel
var meta_list: VBoxContainer
var meta_status: Label
var pending_new_slot: String = ""
var current_view: String = "main"

## 视口缩放因子：以 1920 宽为设计基准，限制范围避免极端过大/过小
func _f() -> float:
	return clamp(get_viewport_rect().size.x / 1920.0, 0.55, 1.8)

func _ready():
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 显式中文字体主题（兜底 root.theme），保证开始界面中文正确显示
	theme = preload("res://ui_theme.tres")
	if not get_viewport().size_changed.is_connected(_on_size_changed):
		get_viewport().size_changed.connect(_on_size_changed)
	_build_all()
	show_only("main")
	refresh_slots()

## 窗口尺寸变化：整体重建并恢复到当前视图，实现自适应
func _on_size_changed():
	_build_all()
	show_only(current_view)
	if current_view == "slot":
		refresh_slots()
	elif current_view == "saves":
		refresh_saves()
	elif current_view == "map":
		refresh_maps()
	elif current_view == "meta":
		refresh_meta()

func _build_all():
	for c in get_children():
		c.queue_free()
	main_buttons.clear()
	_build_bg()
	_build_title()
	_build_main_buttons()
	_build_slot_panel()
	_build_difficulty_panel()
	_build_settings_panel()
	_build_saves_panel()
	_build_map_panel()
	_build_meta_panel()

func _build_bg():
	bg = DecorBgScript.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

func _build_title():
	var f = _f()
	title = Label.new()
	title.text = "幸存者肉鸽"
	title.add_theme_font_size_override("font_size", int(64 * f))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.position = Vector2(0, 80 * f)
	title.size = Vector2(get_viewport_rect().size.x, 90 * f)
	title.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.85))
	title.add_theme_constant_override("shadow_offset_x", 3)
	title.add_theme_constant_override("shadow_offset_y", 3)
	add_child(title)

func _build_main_buttons():
	var f = _f()
	var names = ["开始游戏", "局外强化", "设置", "存档管理"]
	var actions = [_on_start, _on_meta, _on_settings, _on_saves]
	for i in range(names.size()):
		var b = Button.new()
		b.text = names[i]
		b.add_theme_font_size_override("font_size", int(28 * f))
		b.size = Vector2(260 * f, 56 * f)
		b.position = Vector2(get_viewport_rect().size.x / 2.0 - 130 * f, 280 * f + i * 72 * f)
		b.connect("pressed", actions[i])
		add_child(b)
		main_buttons.append(b)

## ---------- 面板切换 ----------
func show_only(which: String) -> void:
	current_view = which
	slot_panel.visible = (which == "slot")
	difficulty_panel.visible = (which == "difficulty")
	settings_panel.visible = (which == "settings")
	saves_panel.visible = (which == "saves")
	map_panel.visible = (which == "map")
	meta_panel.visible = (which == "meta")
	for b in main_buttons:
		b.visible = (which == "main")
	title.visible = (which == "main")

## ---------- 开始游戏 -> 槽位选择 ----------
func _on_start():
	refresh_slots()
	show_only("slot")

func _build_slot_panel():
	var f = _f()
	slot_panel = Panel.new()
	slot_panel.visible = false
	slot_panel.size = Vector2(560 * f, 460 * f)
	slot_panel.position = get_viewport_rect().size / 2.0 - slot_panel.size / 2.0
	add_child(slot_panel)
	var t = Label.new()
	t.text = "选择存档（或新建）"
	t.position = Vector2(20 * f, 12 * f)
	t.add_theme_font_size_override("font_size", int(30 * f))
	slot_panel.add_child(t)
	var back = Button.new()
	back.text = "返回"
	back.position = Vector2(20 * f, 410 * f)
	back.size = Vector2(100 * f, 36 * f)
	back.add_theme_font_size_override("font_size", int(20 * f))
	back.connect("pressed", _on_back)
	slot_panel.add_child(back)

func refresh_slots():
	var f = _f()
	for c in slot_panel.get_children():
		if c is Button and (c.name == "slot_new" or c.name.begins_with("slot_")):
			c.queue_free()
	var slots = SaveManager.list_slots()
	var i = 0
	for sid in slots.keys():
		var s = slots[sid]
		var diff_name = "普通"
		if DataTables.difficulties.has(s.difficulty):
			diff_name = DataTables.difficulties[s.difficulty].name
		var b = Button.new()
		b.name = "slot_" + sid
		b.text = "存档 %s ｜难度：%s ｜最佳：%02d:%02d ｜等级：%d" % [
			sid, diff_name, int(s.best_time) / 60, int(fmod(s.best_time, 60)), int(s.level)]
		b.position = Vector2(20 * f, (50 + i * 56) * f)
		b.size = Vector2(520 * f, 46 * f)
		b.add_theme_font_size_override("font_size", int(20 * f))
		b.connect("pressed", _on_slot_chosen.bind(sid))
		slot_panel.add_child(b)
		i += 1
	var nb = Button.new()
	nb.name = "slot_new"
	nb.text = "＋ 新建存档"
	nb.position = Vector2(20 * f, (50 + i * 56) * f)
	nb.size = Vector2(520 * f, 46 * f)
	nb.add_theme_font_size_override("font_size", int(20 * f))
	nb.connect("pressed", _on_new_slot)
	slot_panel.add_child(nb)

func _on_slot_chosen(sid: String):
	SaveManager.set_active(sid)
	GameManager.set_difficulty(SaveManager.get_slot(sid).difficulty)
	refresh_maps()
	show_only("map")

func _on_new_slot():
	pending_new_slot = "save_" + str(Time.get_ticks_msec())
	show_only("difficulty")

## ---------- 难度选择 ----------
func _on_difficulty_chosen(id: String):
	var sid = pending_new_slot
	if sid == "":
		sid = "save_" + str(Time.get_ticks_msec())
	SaveManager.create_slot(sid, id)
	SaveManager.set_active(sid)
	GameManager.set_difficulty(id)
	pending_new_slot = ""
	refresh_maps()
	show_only("map")

func _build_difficulty_panel():
	var f = _f()
	difficulty_panel = Panel.new()
	difficulty_panel.visible = false
	difficulty_panel.size = Vector2(560 * f, 460 * f)
	difficulty_panel.position = get_viewport_rect().size / 2.0 - difficulty_panel.size / 2.0
	add_child(difficulty_panel)
	var t = Label.new()
	t.text = "选择难度"
	t.position = Vector2(20 * f, 12 * f)
	t.add_theme_font_size_override("font_size", int(30 * f))
	difficulty_panel.add_child(t)
	var back = Button.new()
	back.text = "返回"
	back.position = Vector2(20 * f, 410 * f)
	back.size = Vector2(100 * f, 36 * f)
	back.add_theme_font_size_override("font_size", int(20 * f))
	back.connect("pressed", _on_back)
	difficulty_panel.add_child(back)
	var diffs = ["simple", "normal", "hard", "purgatory", "extreme"]
	for i in range(diffs.size()):
		var d = diffs[i]
		var dd = DataTables.difficulties[d]
		var b = Button.new()
		var suffix = "（敌强×%.1f 奖励×%.1f）" % [dd.enemy_hp, dd.exp]
		if d == "extreme":
			suffix += "  ⚠高负载"
		b.text = dd.name + suffix
		b.position = Vector2(20 * f, (50 + i * 72) * f)
		b.size = Vector2(520 * f, 60 * f)
		b.add_theme_font_size_override("font_size", int(22 * f))
		b.connect("pressed", _on_difficulty_chosen.bind(d))
		difficulty_panel.add_child(b)

func _on_back():
	show_only("main")

## ---------- 地图选择（诸天万界·顺序解锁） ----------
func _build_map_panel():
	var f = _f()
	map_panel = Panel.new()
	map_panel.visible = false
	map_panel.size = Vector2(680 * f, 500 * f)
	map_panel.position = get_viewport_rect().size / 2.0 - map_panel.size / 2.0
	add_child(map_panel)
	var t = Label.new()
	t.text = "选择世界（诸天万界）"
	t.position = Vector2(20 * f, 12 * f)
	t.add_theme_font_size_override("font_size", int(30 * f))
	map_panel.add_child(t)
	var back = Button.new()
	back.text = "返回"
	back.position = Vector2(20 * f, 450 * f)
	back.size = Vector2(100 * f, 36 * f)
	back.add_theme_font_size_override("font_size", int(20 * f))
	back.connect("pressed", _on_map_back)
	map_panel.add_child(back)

func _on_map_back():
	refresh_slots()
	show_only("slot")

## 按 order 排序取地图 id 列表
func _sorted_map_ids() -> Array:
	var ids = DataTables.maps.keys()
	ids.sort_custom(func(a, b): return int(DataTables.maps[a].get("order", 99)) < int(DataTables.maps[b].get("order", 99)))
	return ids

func refresh_maps():
	var f = _f()
	for c in map_panel.get_children():
		if c.name.begins_with("map_"):
			c.queue_free()
	var i = 0
	for mid in _sorted_map_ids():
		var m = DataTables.maps[mid]
		var unlocked = SaveManager.is_map_unlocked(mid)
		var cleared = SaveManager.is_map_cleared(mid)
		var b = Button.new()
		b.name = "map_" + mid
		var mark = ""
		if cleared:
			mark = "  [已通关]"
		elif not unlocked:
			mark = "  [未解锁：需先通关前一世界]"
		# 难度提示：以敌人基础倍率与刷新速率体现递进
		var tip = "敌强×%.2f ｜刷新×%.2f" % [
			float(m.get("enemy_scale_base", 1.0)), float(m.get("base_spawn_rate", 2.0))]
		b.text = "第%d界 · %s\n%s%s" % [int(m.get("order", i + 1)), str(m.get("name", mid)), tip, mark]
		b.position = Vector2(20 * f, (56 + i * 88) * f)
		b.size = Vector2(640 * f, 76 * f)
		b.add_theme_font_size_override("font_size", int(21 * f))
		b.disabled = not unlocked
		if unlocked:
			b.connect("pressed", _on_map_chosen.bind(mid))
		map_panel.add_child(b)
		i += 1

func _on_map_chosen(mid: String):
	GameManager.set_map(mid)
	get_tree().change_scene_to_file("res://scenes/main.tscn")

## ---------- 局外强化商店（金币买初始属性） ----------
func _on_meta():
	refresh_meta()
	show_only("meta")

func _build_meta_panel():
	var f = _f()
	meta_panel = Panel.new()
	meta_panel.visible = false
	meta_panel.size = Vector2(760 * f, 620 * f)
	meta_panel.position = get_viewport_rect().size / 2.0 - meta_panel.size / 2.0
	add_child(meta_panel)
	var t = Label.new()
	t.text = "局外强化（提升每局初始属性）"
	t.position = Vector2(20 * f, 12 * f)
	t.add_theme_font_size_override("font_size", int(30 * f))
	meta_panel.add_child(t)
	meta_status = Label.new()
	meta_status.text = "金币：%d ｜ 绿宝石：%d" % [SaveManager.get_gold(), SaveManager.get_emerald()]
	meta_status.position = Vector2(20 * f, 52 * f)
	meta_status.size = Vector2(700 * f, 28 * f)
	meta_status.add_theme_font_size_override("font_size", int(22 * f))
	meta_status.add_theme_color_override("font_color", Color(1.0, 0.85, 0.35))
	meta_panel.add_child(meta_status)
	var sc = ScrollContainer.new()
	sc.name = "meta_scroll"
	sc.position = Vector2(16 * f, 88 * f)
	sc.size = Vector2(728 * f, 470 * f)
	meta_panel.add_child(sc)
	meta_list = VBoxContainer.new()
	meta_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	meta_list.add_theme_constant_override("separation", int(6 * f))
	sc.add_child(meta_list)
	var back = Button.new()
	back.text = "返回"
	back.position = Vector2(20 * f, 570 * f)
	back.size = Vector2(100 * f, 36 * f)
	back.add_theme_font_size_override("font_size", int(20 * f))
	back.connect("pressed", _on_back)
	meta_panel.add_child(back)

func refresh_meta():
	if meta_list == null:
		return
	var f = _f()
	for c in meta_list.get_children():
		c.queue_free()
	var gold = SaveManager.get_gold()
	var emerald = SaveManager.get_emerald()
	meta_status.text = "金币：%d ｜ 绿宝石：%d" % [gold, emerald]
	var ids = DataTables.meta_upgrades.keys()
	ids.sort()
	for id in ids:
		var u = DataTables.meta_upgrades[id]
		var lvl = SaveManager.get_meta_level(id)
		var maxl = int(u.get("max_level", 1))
		var info = SaveManager.meta_upgrade_cost_info(id)
		var cost = info.cost
		var cur = info.currency
		var b = Button.new()
		b.name = "meta_" + id
		b.custom_minimum_size = Vector2(700 * f, 52 * f)
		b.add_theme_font_size_override("font_size", int(20 * f))
		if cost < 0:
			b.text = "%s  Lv.%d/%d ｜%s ｜已满级" % [str(u.get("name", id)), lvl, maxl, str(u.get("desc", ""))]
			b.disabled = true
		else:
			var cost_label = "升级花费 %d 金" % cost if cur == "gold" else "升级花费 %d 绿宝石" % cost
			b.text = "%s  Lv.%d/%d ｜%s ｜%s" % [str(u.get("name", id)), lvl, maxl, str(u.get("desc", "")), cost_label]
			if cur == "gold":
				b.disabled = gold < cost
			else:
				b.disabled = emerald < cost
			b.connect("pressed", _on_buy_meta.bind(id))
		meta_list.add_child(b)

func _on_buy_meta(id: String):
	if SaveManager.buy_meta_upgrade(id):
		refresh_meta()

## ---------- 设置 ----------
func _build_settings_panel():
	var f = _f()
	settings_panel = Panel.new()
	settings_panel.visible = false
	settings_panel.size = Vector2(560 * f, 360 * f)
	settings_panel.position = get_viewport_rect().size / 2.0 - settings_panel.size / 2.0
	add_child(settings_panel)
	var t = Label.new()
	t.text = "设置"
	t.position = Vector2(20 * f, 12 * f)
	t.add_theme_font_size_override("font_size", int(30 * f))
	settings_panel.add_child(t)
	var mv = Label.new()
	mv.text = "音乐音量"
	mv.position = Vector2(20 * f, 60 * f)
	mv.add_theme_font_size_override("font_size", int(22 * f))
	settings_panel.add_child(mv)
	var slider = HSlider.new()
	slider.name = "music_slider"
	slider.position = Vector2(20 * f, 90 * f)
	slider.size = Vector2(400 * f, 30)
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.value = float(SaveManager.get_setting("music_vol", 0.8))
	slider.connect("value_changed", _on_music_vol)
	settings_panel.add_child(slider)
	var back = Button.new()
	back.text = "返回"
	back.position = Vector2(20 * f, 300 * f)
	back.size = Vector2(100 * f, 36 * f)
	back.add_theme_font_size_override("font_size", int(20 * f))
	back.connect("pressed", _on_back)
	settings_panel.add_child(back)

func _on_music_vol(v: float):
	SaveManager.set_setting("music_vol", v)

func _on_settings():
	show_only("settings")

## ---------- 存档管理 ----------
func _on_saves():
	refresh_saves()
	show_only("saves")

func _build_saves_panel():
	var f = _f()
	saves_panel = Panel.new()
	saves_panel.visible = false
	saves_panel.size = Vector2(640 * f, 460 * f)
	saves_panel.position = get_viewport_rect().size / 2.0 - saves_panel.size / 2.0
	add_child(saves_panel)
	var t = Label.new()
	t.name = "saves_title"
	t.text = "存档管理（全局金币：%d）" % SaveManager.get_gold()
	t.position = Vector2(20 * f, 12 * f)
	t.add_theme_font_size_override("font_size", int(30 * f))
	saves_panel.add_child(t)
	var back = Button.new()
	back.text = "返回"
	back.position = Vector2(20 * f, 410 * f)
	back.size = Vector2(100 * f, 36 * f)
	back.add_theme_font_size_override("font_size", int(20 * f))
	back.connect("pressed", _on_back)
	saves_panel.add_child(back)

func refresh_saves():
	var f = _f()
	for c in saves_panel.get_children():
		if c is Button and (c.name.begins_with("del_") or c.name.begins_with("info_")):
			c.queue_free()
	var title = saves_panel.get_node_or_null("saves_title")
	if title:
		title.text = "存档管理（全局金币：%d）" % SaveManager.get_gold()
	var slots = SaveManager.list_slots()
	var i = 0
	for sid in slots.keys():
		var s = slots[sid]
		var diff_name = "普通"
		if DataTables.difficulties.has(s.difficulty):
			diff_name = DataTables.difficulties[s.difficulty].name
		var info = Label.new()
		info.name = "info_" + sid
		info.text = "存档 %s ｜难度：%s ｜最佳：%02d:%02d ｜等级：%d" % [
			sid, diff_name, int(s.best_time) / 60, int(fmod(s.best_time, 60)), int(s.level)]
		info.position = Vector2(20 * f, (50 + i * 64) * f)
		info.size = Vector2(420 * f, 30 * f)
		info.add_theme_font_size_override("font_size", int(20 * f))
		saves_panel.add_child(info)
		var del = Button.new()
		del.name = "del_" + sid
		del.text = "删除"
		del.position = Vector2(470 * f, (50 + i * 64) * f)
		del.size = Vector2(100 * f, 36 * f)
		del.add_theme_font_size_override("font_size", int(20 * f))
		del.connect("pressed", _on_delete_slot.bind(sid))
		saves_panel.add_child(del)
		i += 1
	if slots.is_empty():
		var empty = Label.new()
		empty.name = "info_empty"
		empty.text = "（暂无存档，请从「开始游戏」新建）"
		empty.position = Vector2(20 * f, 50 * f)
		empty.add_theme_font_size_override("font_size", int(20 * f))
		saves_panel.add_child(empty)

func _on_delete_slot(sid: String):
	SaveManager.delete_slot(sid)
	refresh_saves()
