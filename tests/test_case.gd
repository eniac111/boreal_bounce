class_name TestCase
extends RefCounted
## Minimal test base class. Subclasses define methods named test_*; assertions record
## failures instead of aborting so one run reports everything.

var failures: Array[String] = []
var checks := 0


func assert_true(cond: bool, msg := "") -> void:
	checks += 1
	if not cond:
		failures.append("assert_true failed" + (": " + msg if msg else ""))


func assert_false(cond: bool, msg := "") -> void:
	assert_true(not cond, msg)


func assert_eq(actual, expected, msg := "") -> void:
	checks += 1
	if not _same(actual, expected):
		failures.append("expected %s, got %s%s" % [str(expected), str(actual), (" (" + msg + ")" if msg else "")])


func assert_near(actual: float, expected: float, tolerance := 1e-6, msg := "") -> void:
	checks += 1
	if absf(actual - expected) > tolerance:
		failures.append("expected %s ± %s, got %s%s" % [expected, tolerance, actual, (" (" + msg + ")" if msg else "")])


func _same(a, b) -> bool:
	if typeof(a) != typeof(b):
		if (typeof(a) == TYPE_INT and typeof(b) == TYPE_FLOAT) or (typeof(a) == TYPE_FLOAT and typeof(b) == TYPE_INT):
			return float(a) == float(b)
		if typeof(a) in [TYPE_STRING, TYPE_STRING_NAME] and typeof(b) in [TYPE_STRING, TYPE_STRING_NAME]:
			return String(a) == String(b)
		return false
	return a == b
