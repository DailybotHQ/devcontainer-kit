# shellcheck shell=bash
# Fixture scope: a nested run's PATH hides the planted host ak, keeps its neighbours.

test_planted() {
  if command -v ak >/dev/null 2>&1; then fail "ak is hidden" "found: $(command -v ak)"; else pass "ak is hidden"; fi
  assert_eq "$(keepme)" "kept" "the other executables of that directory still run"
}
