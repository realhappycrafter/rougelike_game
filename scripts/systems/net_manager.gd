extends Node
## NetManager —— 联机接入层（零成本方案：WebSocket 中继 + host 权威）
## 默认 mode = SOLO：不建立任何连接，完全不影响现有单人玩法。
## process_mode = ALWAYS：即使场景树因升级暂停，仍持续 poll 中继，保持连接不丢。
## 由 main 在需要时调用 connect_relay() 进入 HOST 或 GUEST。
## 本脚本只负责 WebSocket 连接与 JSON 消息的收发，不碰任何游戏逻辑。
##
## 连接握手约定（与 relay/server.js 配合）：
##   1) 客户端连上后，中继立即单播一个 welcome 帧，告知本端被分配的 pid；
##   2) NetManager 收到 welcome 后才补发 join（携带 pid + 是否主机），
##      保证房内其他人能据此识别身份并建代理。

enum Mode { SOLO, HOST, GUEST }

var mode: int = Mode.SOLO
var ws: WebSocketPeer = null
var relay_url: String = "ws://localhost:8080"
var room: String = "default"
var my_pid: int = -1
var is_connected: bool = false

# 客机端：最近一次世界快照（由 main 读取做远端渲染 / 本端预测）
var last_state: Dictionary = {}

# 收到对端/服务器文本消息（已解析为 Dictionary）时触发，由 main 订阅
signal message_received(msg: Dictionary)
# 连接状态变化
signal connected_changed(ok: bool)

func _ready() -> void:
	# 暂停（升级三选一）期间也要保持 WebSocket 轮询，避免中继连接被服务器因无 pong 而断开
	process_mode = Node.PROCESS_MODE_ALWAYS

func connect_relay(p_relay_url: String = "", p_room: String = "default", p_is_host: bool = false) -> void:
	if p_relay_url != "":
		relay_url = p_relay_url
	room = p_room
	mode = Mode.HOST if p_is_host else Mode.GUEST
	ws = WebSocketPeer.new()
	# Godot 的 WebSocketPeer 要求 host:port 后必须有路径（至少 "/")，
	# 否则 "ws://host:port?room=x" 会被判为非法 URL（code=31）。补一个斜杠。
	var base = relay_url
	if not base.ends_with("/"):
		base += "/"
	var url = "%s?room=%s" % [base, room]
	var err = ws.connect_to_url(url)
	if err != OK:
		push_error("NetManager: 连接失败 code=%d" % err)
		return

func _process(_delta: float) -> void:
	if ws == null:
		return
	ws.poll()
	var state = ws.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if not is_connected:
			is_connected = true
			connected_changed.emit(true)
		while ws.get_available_packet_count() > 0:
			var raw = ws.get_packet().get_string_from_utf8()
			var msg = JSON.parse_string(raw)
			if msg is Dictionary:
				_handle(msg)
	elif state == WebSocketPeer.STATE_CLOSED:
		if is_connected:
			is_connected = false
			connected_changed.emit(false)
		ws = null

## 统一分发：welcome 设置 pid 后补发 join；state 存为 last_state 供客机渲染
func _handle(msg: Dictionary) -> void:
	var t = msg.get("t", "")
	if t == "welcome":
		my_pid = int(msg.get("pid", -1))
		_send({"t": "join", "pid": my_pid, "room": room, "host": mode == Mode.HOST})
		message_received.emit(msg)
	elif t == "state":
		last_state = msg
		message_received.emit(msg)
	else:
		message_received.emit(msg)

## 发送任意 JSON 消息（文本帧）
func _send(msg: Dictionary) -> void:
	if ws != null and ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify(msg))

## 客机把本地输入发给 host（move/aim 为单位向量或零向量）
func send_input(move: Vector2, aim: Vector2) -> void:
	_send({"t": "input", "pid": my_pid, "mx": move.x, "my": move.y, "ax": aim.x, "ay": aim.y})

## host 把世界快照广播给同房客机（players 紧凑数组 + enemies 紧凑数组）
func send_snapshot(players: Array, enemies: Array, run_time: float, kills: int) -> void:
	_send({"t": "state", "rt": run_time, "kills": kills, "players": players, "enemies": enemies})

func disconnect_relay() -> void:
	if ws != null:
		ws.close()
		ws = null
	is_connected = false
	mode = Mode.SOLO
	my_pid = -1
	last_state = {}
