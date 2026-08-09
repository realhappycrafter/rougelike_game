extends Node
## AudioManager —— 音效/音乐占位（GDD §13.2）
## 当前为无操作占位，后续接入免费素材库（OpenGameArt / Freesound）。
## Web 端需注意：音频初始化需用户首次交互（浏览器策略）。

func _ready():
	pass

func play_sfx(_name: String) -> void:
	# TODO: 加载并播放音效
	pass

func play_music(_name: String) -> void:
	# TODO: 加载并循环播放背景音乐
	pass

func set_volume(_v: float) -> void:
	pass
