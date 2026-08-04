class_name GitPluginTestCase
extends RefCounted

var failures: Array[String] = []

func assert_true(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		printerr("ASSERT: ", message)

func assert_eq(actual: Variant, expected: Variant, message: String = "") -> void:
	if actual != expected:
		var detail := message
		if detail.is_empty():
			detail = "expected %s, got %s" % [str(expected), str(actual)]
		failures.append(detail)
		printerr("ASSERT: ", detail)

func run() -> bool:
	return failures.is_empty()
