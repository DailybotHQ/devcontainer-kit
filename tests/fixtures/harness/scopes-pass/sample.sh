# Fixture scope used by the harness scope: two passing tests, noise on stdout.
test_one() {
  echo "ok - this stdout line is noise and must not be counted"
  assert_eq "a" "a" "equal strings"
}
test_two() {
  assert_contains "hello world" "world" "substring"
  require_docker "docker-dependent check" || return 0
  pass "docker answered"
}
