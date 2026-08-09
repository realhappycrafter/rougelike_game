@tool
extends SceneTree

func _initialize():
	if not Engine.has_singleton("EditorInterface"):
		print("NO_EDITOR_INTERFACE")
		quit()
	var count = EditorInterface.get_export_preset_count()
	print("PRESET_COUNT=" + str(count))
	for i in count:
		var preset = EditorInterface.get_export_preset(i)
		var pname = preset.get_name()
		print("PRESET_" + str(i) + "=" + pname)
		if pname == "Android":
			var opt_count = preset.get_options_count()
			print("OPT_COUNT=" + str(opt_count))
			for j in opt_count:
				var oname = preset.get_option_name(j)
				if "package" in oname or "name" in oname or "version" in oname or "orient" in oname or "icon" in oname or "immersive" in oname:
					print("OPT: " + oname)
	quit()
