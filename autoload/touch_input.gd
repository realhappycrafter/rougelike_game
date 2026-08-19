extends Node2D
## TouchInput —— 移动端虚拟摇杆（浮动式）
## 在手指首次触屏处生成摇杆底座，拖动方向即移动方向（经典“灵魂摇杆”）。
## 仅在真实触屏设备（Android/iOS）激活；桌面端保持纯键盘，不受影响。
## player.gd 通过 get_move_vector() 取移动向量（含死区与强度，长度 0~1）。

const RADIUS := 90.0          # 摇杆底座半径（设计像素，随拉伸自动缩放）
const DEAD := 12.0            # 死区半径，避免误触抖动
const MAX_LAYER := 100        # 高于 UI 的 CanvasLayer，确保摇杆绘制在 HUD 之上

var active := false
var touch_index := -1
var origin := Vector2.ZERO    # 摇杆底座中心（手指按下处）
var pointer := Vector2.ZERO   # 当前手指位置

func _ready() -> void:
	# 暂停时仍需接收触摸（例如暂停中抬起手指），故设为常驻处理
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 根节点正在装配 autoload，此刻不能直接 add_child 到 root，延后到空闲再挂载图层
	call_deferred("_setup_layer")

func _setup_layer() -> void:
	var cl := CanvasLayer.new()
	cl.name = "TouchInputLayer"
	cl.layer = MAX_LAYER
	get_tree().root.add_child(cl)
	reparent(cl)   # 把自身移入高层级 CanvasLayer，使其绘制层级高于 HUD

func _input(event: InputEvent) -> void:
	# 仅在真实触屏设备启用；桌面鼠标模拟的触摸事件被忽略，键盘逻辑不受影响
	if not (OS.has_feature("android") or OS.has_feature("ios")):
		return
	# 仅在进行中的对局激活摇杆：开始/局外升级/职业选择/暂停/升级三选一等
	# 界面不接管触摸，避免摇杆遮挡并吞掉面板的滑动手势（用户反馈的滚动困难）。
	if not (GameManager.playing and not get_tree().paused):
		if active:
			active = false
			touch_index = -1
			queue_redraw()
		return
	if event is InputEventScreenTouch:
		if event.pressed and touch_index < 0:
			touch_index = event.index
			origin = event.position
			pointer = event.position
			active = true
			queue_redraw()
		elif not event.pressed and event.index == touch_index:
			active = false
			touch_index = -1
			queue_redraw()
	elif event is InputEventScreenDrag and event.index == touch_index:
		pointer = event.position
		queue_redraw()

func _draw() -> void:
	if not active:
		return
	draw_circle(origin, RADIUS, Color(1, 1, 1, 0.12))
	draw_arc(origin, RADIUS, 0.0, TAU, 48, Color(1, 1, 1, 0.35), 3.0)
	var stick_pos := origin + (pointer - origin).limit_length(RADIUS)
	draw_circle(stick_pos, 42.0, Color(1, 1, 1, 0.45))

## 返回移动向量：死区内为 ZERO；推到边缘为长度 1 的方向向量（模拟摇杆支持部分推力）
func get_move_vector() -> Vector2:
	if not active:
		return Vector2.ZERO
	var diff := pointer - origin
	if diff.length() <= DEAD:
		return Vector2.ZERO
	return diff.limit_length(RADIUS) / RADIUS
