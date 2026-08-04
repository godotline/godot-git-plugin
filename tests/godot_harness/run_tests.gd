extends SceneTree

func _init() -> void:
	var user_args := OS.get_cmdline_user_args()
	var case_name := ""
	if not user_args.is_empty():
		case_name = user_args[0]

	var cases := []
	if case_name.is_empty():
		cases = ["test_backend_contract"]
	else:
		cases = [case_name]

	var failed := 0
	for current_case in cases:
		var script_path := "res://cases/%s.gd" % current_case
		if not ResourceLoader.exists(script_path):
			printerr("Missing test case: ", script_path)
			failed += 1
			continue
		var test_case = load(script_path).new()
		var result = test_case.run()
		if result is bool and result:
			print("PASS ", current_case)
		else:
			printerr("FAIL ", current_case)
			failed += 1

	print("TESTS failed=%d total=%d" % [failed, cases.size()])
	quit(1 if failed > 0 else 0)
