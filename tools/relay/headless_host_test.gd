extends SceneTree
## 无头 HOST 联机驱动：加载 main 场景，等就绪后进入主机模式，
## 让 WebSocketPeer 与中继握手并持续广播 ~6s，捕获任何运行时错误。

var main = null
var tried = false

func _initialize() -> void:
	var packed = load("res://scenes/main.tscn")
	main = packed.instantiate()
	root.add_child(main)
	print("HOST_TEST: main instantiated, root children=", root.get_child_count())

func _process(_delta: float) -> bool:
	if tried:
		return false
	# 等 main 真正就绪（_ready 跑完）再连接
	if not is_instance_valid(main):
		return false
	if not main.is_inside_tree():
		return false
	if not main.has_method("_connect_as"):
		printerr("HOST_TEST: _connect_as 方法缺失")
		tried = true
		quit(1)
		return false
	tried = true
	main._connect_as(true, "room1", "ws://localhost:8080")
	print("HOST_TEST: 已调用 _connect_as(主机)")
	var t = create_timer(6.0)
	t.timeout.connect(func():
		print("HOST_TEST: 退出前 remote_players(代理数)=%d" % [main.remote_players.size()])
		quit(0)
	)
	return false
