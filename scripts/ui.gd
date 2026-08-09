extends Control
## UI —— HUD / 升级三选一弹窗 / 暂停菜单 / 结算界面（GDD §12）
## 常驻处理（PROCESS_MODE_ALWAYS），游戏暂停时仍可交互。
## 通过 option_selected / restart_requested 信号把选择回传 main。

signal option_selected(index: int)
signal restart_requested()

var timer_label: Label
var hp_bar: ProgressBar
var hp_label: Label
var exp_bar: ProgressBar
var level_label: Label
var kill_label: Label
var gold_label: Label
var weapon_label: Label

var enemy_label: Label      # 实时敌人计数（HUD 顶部）
var warn_label: Label       # 极端模式性能警告（开局短暂显示）
var warn_timer: float = 0.0

var stage_label: Label      # 阶段 / BOSS战 指示（左上）
var banner: Label           # 大型事件横幅（Boss 战 / 阶段开始）
var banner_timer: float = 0.0
var log_labels = []         # 底部滚动日志标签池（最多 6 条）
var log_msgs = []           # {text, color, life}

var levelup_panel: Panel
var levelup_buttons = []
var levelup_dim: ColorRect
var results_panel: Panel
var results_label: Label
var results_dim: ColorRect

var pause_panel: Panel
var pause_dim: ColorRect
var paused: bool = false

var _vs = Vector2(1920, 1080)

func _ready():
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_STOP
	# 显式中文字体主题：兜底 root.theme，确保 CanvasLayer 下动态创建的
	# HUD / 升级 / 暂停控件都能正确显示中文（避免回退到拉丁默认字体导致方块/乱码）。
	theme = preload("res://ui_theme.tres")
	_vs = get_viewport_rect().size
	if _vs.x < 10:
		_vs = Vector2(1920, 1080)

## 视口缩放因子：以 1920 宽为设计基准，限制范围避免极端过大/过小
func _f() -> float:
	return clamp(_vs.x / 1920.0, 0.6, 1.8)

## 给 HUD 文字加半透明暗色底框，提升在暗色地面上的可读性
func _label_bg(lbl: Control, alpha: float = 0.5) -> void:
	var sb = StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.04, 0.08, alpha)
	sb.set_content_margin_all(5)
	lbl.add_theme_stylebox_override("normal", sb)

func init_hud() -> void:
	_vs = get_viewport_rect().size
	if _vs.x < 10:
		_vs = Vector2(1920, 1080)
	timer_label = Label.new()
	timer_label.position = Vector2(20, 15)
	timer_label.add_theme_font_size_override("font_size", int(30 * _f()))
	add_child(timer_label)

	hp_bar = ProgressBar.new()
	hp_bar.position = Vector2(20, _vs.y - 70 * _f())
	hp_bar.size = Vector2(320 * _f(), 22 * _f())
	hp_bar.show_percentage = false
	add_child(hp_bar)

	hp_label = Label.new()
	hp_label.position = Vector2(26, _vs.y - 68 * _f())
	hp_label.add_theme_font_size_override("font_size", int(16 * _f()))
	add_child(hp_label)

	exp_bar = ProgressBar.new()
	exp_bar.position = Vector2(20, _vs.y - 44 * _f())
	exp_bar.size = Vector2(320 * _f(), 14 * _f())
	exp_bar.show_percentage = false
	add_child(exp_bar)

	level_label = Label.new()
	level_label.position = Vector2(355 * _f(), _vs.y - 70 * _f())
	level_label.add_theme_font_size_override("font_size", int(22 * _f()))
	add_child(level_label)

	kill_label = Label.new()
	kill_label.position = Vector2(20, _vs.y - 20 * _f())
	kill_label.add_theme_font_size_override("font_size", int(16 * _f()))
	add_child(kill_label)

	gold_label = Label.new()
	gold_label.position = Vector2(180 * _f(), _vs.y - 20 * _f())
	gold_label.add_theme_font_size_override("font_size", int(16 * _f()))
	add_child(gold_label)

	weapon_label = Label.new()
	weapon_label.position = Vector2(_vs.x - 320 * _f(), 15)
	weapon_label.add_theme_font_size_override("font_size", int(16 * _f()))
	add_child(weapon_label)

	# 屏幕暂停按钮：移动端无键盘（ESC/P 不可用）时也能暂停
	var pause_btn = Button.new()
	pause_btn.name = "pause_btn"
	pause_btn.text = "暂停"
	pause_btn.add_theme_font_size_override("font_size", int(20 * _f()))
	pause_btn.size = Vector2(64 * _f(), 40 * _f())
	pause_btn.position = Vector2(_vs.x - 72 * _f(), 14 * _f())
	pause_btn.connect("pressed", toggle_pause)
	add_child(pause_btn)
	_label_bg(pause_btn)

	# 实时敌人计数（顶部居中）
	enemy_label = Label.new()
	enemy_label.position = Vector2(_vs.x / 2.0 - 70 * _f(), 15)
	enemy_label.add_theme_font_size_override("font_size", int(22 * _f()))
	enemy_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.95, 1.0))
	add_child(enemy_label)

	# 阶段指示（左上，计时器下方）
	stage_label = Label.new()
	stage_label.position = Vector2(20, 55 * _f())
	stage_label.add_theme_font_size_override("font_size", int(22 * _f()))
	stage_label.add_theme_color_override("font_color", Color(0.6, 0.9, 1.0))
	add_child(stage_label)

	# 极端模式性能警告（默认隐藏，由 main 在极端难度开局调用）
	warn_label = Label.new()
	warn_label.visible = false
	warn_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	warn_label.position = Vector2(0, 120 * _f())
	warn_label.size = Vector2(_vs.x, 40 * _f())
	warn_label.add_theme_font_size_override("font_size", int(24 * _f()))
	warn_label.add_theme_color_override("font_color", Color(1.0, 0.75, 0.2, 1.0))
	add_child(warn_label)

	# 大型事件横幅（Boss 战等）
	banner = Label.new()
	banner.visible = false
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.position = Vector2(0, 200 * _f())
	banner.size = Vector2(_vs.x, 50 * _f())
	banner.add_theme_font_size_override("font_size", int(34 * _f()))
	add_child(banner)
	# 底部滚动日志（最多 6 条，自动淡出）
	for i in range(6):
		var l = Label.new()
		l.visible = false
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.add_theme_font_size_override("font_size", int(18 * _f()))
		add_child(l)
		log_labels.append(l)

	# HUD 文字半透明暗底框（可读性）
	for lbl in [timer_label, enemy_label, stage_label, hp_label, kill_label, gold_label, weapon_label]:
		_label_bg(lbl)

	_build_levelup_panel()
	_build_results_panel()
	_build_pause_panel()

func update_hud() -> void:
	if timer_label == null:
		return
	var t = GameManager.run_time
	var mm = int(t / 60)
	var ss = int(fmod(t, 60))
	timer_label.text = "%02d:%02d" % [mm, ss]
	var p = GameManager.player
	if p:
		hp_bar.max_value = p.max_hp
		hp_bar.value = p.hp
		hp_label.text = "%d / %d" % [int(p.hp), int(p.max_hp)]
	exp_bar.max_value = GameManager.exp_needed
	exp_bar.value = GameManager.exp
	level_label.text = "Lv " + str(GameManager.level)
	kill_label.text = "击杀 " + str(GameManager.kills)
	gold_label.text = "金币 " + str(GameManager.gold)
	if p:
		var s = ""
		for wid in p.weapons.keys():
			s += DataTables.weapons[wid].name + " " + str(p.weapons[wid].level) + "\n"
		for pid in p.passives.keys():
			s += DataTables.passives[pid].name + " " + str(p.passives[pid].level) + "[" + str(p.passives[pid].quality) + "]\n"
		weapon_label.text = s

func _build_levelup_panel() -> void:
	var f = _f()
	levelup_dim = ColorRect.new()
	levelup_dim.color = Color(0.03, 0.02, 0.05, 0.62)
	levelup_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	levelup_dim.visible = false
	add_child(levelup_dim)
	levelup_panel = Panel.new()
	levelup_panel.visible = false
	levelup_panel.position = (_vs - Vector2(920, 280) * f) / 2.0
	levelup_panel.size = Vector2(920, 280) * f
	add_child(levelup_panel)

	var title = Label.new()
	title.text = "升级！选择一项（1 / 2 / 3 或点击）"
	title.position = Vector2(20 * f, 12 * f)
	title.add_theme_font_size_override("font_size", int(26 * f))
	levelup_panel.add_child(title)

	for i in range(3):
		var b = Button.new()
		b.position = Vector2(20 * f + i * 295 * f, 55 * f)
		b.size = Vector2(275 * f, 200 * f)
		b.add_theme_font_size_override("font_size", int(20 * f))
		b.connect("pressed", _on_button_pressed.bind(i))
		levelup_panel.add_child(b)
		levelup_buttons.append(b)

func show_level_up(options: Array) -> void:
	# 防御：升级弹窗出现时确保暂停菜单已隐藏（二者不会同时出现）
	if pause_panel != null:
		pause_panel.visible = false
	paused = false
	for i in range(3):
		if i < options.size():
			var o = options[i]
			levelup_buttons[i].visible = true
			levelup_buttons[i].text = o.name + "\n\n" + o.desc
			var col = Color(1, 1, 1, 1)
			if o.has("quality_color") and o.quality_color != null:
				col = Color.from_string(o.quality_color, Color.WHITE)
			levelup_buttons[i].add_theme_color_override("font_color", col)
		else:
			levelup_buttons[i].visible = false
	levelup_panel.visible = true
	levelup_dim.visible = true

func hide_level_up() -> void:
	levelup_panel.visible = false
	levelup_dim.visible = false

func _on_button_pressed(i: int) -> void:
	emit_signal("option_selected", i)

func _build_results_panel() -> void:
	var f = _f()
	results_dim = ColorRect.new()
	results_dim.color = Color(0.03, 0.02, 0.05, 0.66)
	results_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	results_dim.visible = false
	add_child(results_dim)
	results_panel = Panel.new()
	results_panel.visible = false
	results_panel.position = (_vs - Vector2(520, 380) * f) / 2.0
	results_panel.size = Vector2(520, 380) * f
	add_child(results_panel)

	results_label = Label.new()
	results_label.position = Vector2(20 * f, 20 * f)
	results_label.size = Vector2(480 * f, 260 * f)
	results_label.add_theme_font_size_override("font_size", int(20 * f))
	results_panel.add_child(results_label)

	var b = Button.new()
	b.text = "再来一局"
	b.position = Vector2(120 * f, 300 * f)
	b.size = Vector2(140 * f, 50 * f)
	b.add_theme_font_size_override("font_size", int(20 * f))
	b.connect("pressed", _on_restart_pressed)
	results_panel.add_child(b)

	var bm = Button.new()
	bm.text = "主菜单"
	bm.position = Vector2(270 * f, 300 * f)
	bm.size = Vector2(140 * f, 50 * f)
	bm.add_theme_font_size_override("font_size", int(20 * f))
	bm.connect("pressed", _on_menu_pressed)
	results_panel.add_child(bm)

func show_results(stats: Dictionary) -> void:
	var t = float(stats["time"])
	var mm = int(t / 60)
	var ss = int(fmod(t, 60))
	results_label.text = (
		"本局结束\n\n" +
		"存活  %02d:%02d\n" % [mm, ss] +
		"击杀  " + str(stats["kills"]) + "\n" +
		"等级  " + str(stats["level"]) + "\n" +
		"金币  +" + str(stats["gold"]) + "\n" +
		"原因  " + str(stats["reason"])
	)
	results_panel.visible = true
	results_dim.visible = true

func _on_restart_pressed() -> void:
	emit_signal("restart_requested")

func _on_menu_pressed() -> void:
	get_tree().paused = false
	paused = false
	get_tree().change_scene_to_file("res://scenes/menu.tscn")

## ---------- 暂停菜单 ----------
func _build_pause_panel() -> void:
	var f = _f()
	pause_dim = ColorRect.new()
	pause_dim.color = Color(0.03, 0.02, 0.05, 0.6)
	pause_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pause_dim.visible = false
	add_child(pause_dim)
	pause_panel = Panel.new()
	pause_panel.visible = false
	pause_panel.size = Vector2(420, 240) * f
	pause_panel.position = (_vs - pause_panel.size) / 2.0
	add_child(pause_panel)

	var t = Label.new()
	t.text = "已暂停"
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.add_theme_font_size_override("font_size", int(40 * f))
	t.position = Vector2(0, 20 * f)
	t.size = Vector2(pause_panel.size.x, 60 * f)
	pause_panel.add_child(t)

	var resume = Button.new()
	resume.text = "继续"
	resume.add_theme_font_size_override("font_size", int(24 * f))
	resume.size = Vector2(180 * f, 56 * f)
	resume.position = Vector2(pause_panel.size.x / 2.0 - 90 * f, 110 * f)
	resume.connect("pressed", _on_resume)
	pause_panel.add_child(resume)

	var to_menu = Button.new()
	to_menu.text = "回主菜单"
	to_menu.add_theme_font_size_override("font_size", int(24 * f))
	to_menu.size = Vector2(180 * f, 56 * f)
	to_menu.position = Vector2(pause_panel.size.x / 2.0 - 90 * f, 180 * f)
	to_menu.connect("pressed", _on_pause_menu)
	pause_panel.add_child(to_menu)

func _on_resume() -> void:
	_set_paused(false)

func _on_pause_menu() -> void:
	paused = false
	get_tree().paused = false
	get_tree().change_scene_to_file("res://scenes/menu.tscn")

func _set_paused(p: bool) -> void:
	if p == paused:
		return
	paused = p
	get_tree().paused = p
	pause_panel.visible = p
	pause_dim.visible = p

func toggle_pause() -> void:
	# 升级或结算时不可暂停，避免与现有 paused 状态冲突
	if levelup_panel != null and levelup_panel.visible:
		return
	if results_panel != null and results_panel.visible:
		return
	_set_paused(not paused)

func _process(delta: float) -> void:
	if enemy_label != null and EnemyManager != null:
		enemy_label.text = "敌人 " + str(EnemyManager.alive_count())
	if warn_label != null and warn_label.visible and warn_timer > 0.0:
		warn_timer -= delta
		if warn_timer <= 0.0:
			warn_label.visible = false
	_update_info_fx(delta)

func show_perf_warning(msg: String) -> void:
	if warn_label == null:
		return
	warn_label.text = msg
	warn_label.visible = true
	warn_timer = 5.0

## ---- 事件信息框 ----
## big=true 走顶部大横幅（Boss 战等），否则走底部滚动日志（宝箱/新怪加入等）
func info(text: String, color: Color = Color(0.9, 0.9, 0.95), big: bool = false) -> void:
	if big:
		_show_banner(text, color)
	else:
		_push_log(text, color)

func _show_banner(text: String, color: Color) -> void:
	if banner == null:
		return
	banner.text = text
	banner.add_theme_color_override("font_color", color)
	banner.visible = true
	banner.modulate.a = 1.0
	banner_timer = 4.0

func _push_log(text: String, color: Color) -> void:
	log_msgs.append({ "text": text, "color": color, "life": 6.0 })
	if log_msgs.size() > 6:
		log_msgs.pop_front()

func set_stage(idx: int, state: String) -> void:
	if stage_label == null:
		return
	if state == "boss":
		stage_label.text = "BOSS战"
		stage_label.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
	else:
		stage_label.text = "第 " + str(idx + 1) + " 阶段"
		stage_label.add_theme_color_override("font_color", Color(0.6, 0.9, 1.0))

## 每帧淡出横幅与滚动日志并重新布局
func _update_info_fx(delta: float) -> void:
	if banner != null and banner.visible:
		banner_timer -= delta
		if banner_timer <= 0.0:
			banner.visible = false
		else:
			banner.modulate.a = clamp(banner_timer / 1.0, 0.0, 1.0)
	for m in log_msgs:
		m.life -= delta
	while log_msgs.size() > 0 and log_msgs[0].life <= 0.0:
		log_msgs.pop_front()
	var n = log_msgs.size()
	for i in range(log_labels.size()):
		var lbl = log_labels[i]
		if i < n:
			var m = log_msgs[n - 1 - i]
			lbl.visible = true
			lbl.text = m.text
			lbl.add_theme_color_override("font_color", m.color)
			lbl.modulate.a = clamp(m.life / 1.5, 0.0, 1.0)
			lbl.position = Vector2(_vs.x / 2.0 - 220 * _f(), _vs.y - 170 * _f() - i * 26 * _f())
			lbl.size = Vector2(440 * _f(), 24 * _f())
		else:
			lbl.visible = false

func _unhandled_input(event) -> void:
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_ESCAPE or event.keycode == KEY_P:
			toggle_pause()
			return
		if levelup_panel and levelup_panel.visible:
			if event.keycode == KEY_1:
				_on_button_pressed(0)
			elif event.keycode == KEY_2:
				_on_button_pressed(1)
			elif event.keycode == KEY_3:
				_on_button_pressed(2)
