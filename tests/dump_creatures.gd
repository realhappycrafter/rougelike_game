extends Node
## 临时脚本：把 CreatureVisual 生成的怪物/玩家贴图（含动画帧）导出为 PNG，
## 便于人工核对「三界风格 + 动态帧」。仅用于本地预览，不参与游戏运行。

const CreatureVisual = preload("res://scripts/systems/creature_visual.gd")

func _ready() -> void:
	var out_dir = "D:/rougelike/rougelike_game/creature_dump"
	# 怪物：每 shape 导出 frame 0/1（走路）与 frame 2（攻击），文件名带 f0/f1/f2
	var enemy_samples = [
		# [world, shape, Color(r,g,b)]
		["zombie",  "imp",   Color(0.753, 0.224, 0.169)],
		["zombie",  "brute", Color(0.086, 0.627, 0.520)],
		["zombie",  "wraith", Color(0.600, 0.320, 0.780)],
		["douluo",  "imp",   Color(0.180, 0.525, 0.871)],
		["douluo",  "boss",  Color(0.945, 0.769, 0.059)],
		["xiuxian", "fast",  Color(0.902, 0.494, 0.133)],
		["xiuxian", "boss",  Color(0.753, 0.224, 0.169)],
	]
	for s in enemy_samples:
		for f in [0, 1, 2]:
			var tex = CreatureVisual.get_enemy_texture(s[1], s[2], s[0], f)
			var img = tex.get_image()
			var p = out_dir.path_join("creature_%s_%s_f%d.png" % [s[0], s[1], f])
			var err = img.save_png(p)
			print("[dump] enemy %s f%d -> err=%d" % [s[1], f, err])
	# 玩家：6 职业 + 默认，frame 0/1 双脚步态
	var classes = ["warrior", "archer", "guardian", "element_mage", "summoner", "healer", ""]
	for cid in classes:
		for f in [0, 1]:
			var tex = CreatureVisual.get_player_texture(cid, f)
			var img = tex.get_image()
			var name = cid if cid != "" else "default"
			var p = out_dir.path_join("player_%s_f%d.png" % [name, f])
			var err = img.save_png(p)
			print("[dump] player %s f%d -> err=%d" % [name, f, err])
	get_tree().quit()
