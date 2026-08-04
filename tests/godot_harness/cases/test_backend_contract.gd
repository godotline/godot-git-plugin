extends "res://support/test_case.gd"

func run() -> bool:
	assert_true(ClassDB.class_exists("GitPlugin"), "GitPlugin must be registered")
	if failures.is_empty():
		var backend = ClassDB.instantiate("GitPlugin")
		for method_name in [
			"collaboration_initialize",
			"collaboration_get_repository_state",
			"collaboration_get_refs",
			"collaboration_diff_refs",
			"collaboration_get_blob",
			"collaboration_analyze_merge",
			"collaboration_merge_ref",
			"collaboration_get_conflicts",
			"collaboration_get_conflict_blob",
			"collaboration_write_and_stage",
		]:
			assert_true(backend.has_method(method_name), "Missing method: " + method_name)
	return failures.is_empty()
