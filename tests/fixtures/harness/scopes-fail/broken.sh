# Fixture scope used by the harness scope: every way a test can fail.
test_failed_assertion() { assert_eq "a" "b" "deliberately unequal"; }
test_crash() { false_command_that_does_not_exist; return 3; }
test_silent() { :; }
test_passing() { pass "one passing line"; }
