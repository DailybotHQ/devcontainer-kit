# shellcheck shell=bash
#
# lib/doctor.sh — `dck doctor [--json] [--strict]` and `dck --skill`.
# The doctor works anywhere (outside a repository it reports the host only)
# and never fails because something it probes is broken: it reports it.

DCK_VERBS="$DCK_VERBS doctor "

dck_cmd_doctor() {
  local a=() arg
  for arg in "$@"; do
    case "$arg" in
      --json|--strict) a+=("$arg") ;;
      *) die "$DCK_EXIT_USAGE" "usage: dck doctor [--json] [--strict]" ;;
    esac
  done
  [ -n "$DCK_PROFILE_NAME" ] && a+=(--profile "$DCK_PROFILE_NAME")
  [ -n "$DCK_REPO_ARG" ] && a+=(--repo "$DCK_REPO_ARG")
  dckpy doctor ${a[@]+"${a[@]}"}
}

# The bundled agent skill (skills/dck/SKILL.md), for agents that load skills
# from a command's output.
dck_print_skill() {
  local name="${1:-dck}"
  case "$name" in ''|*[!a-z0-9-]*) die "$DCK_EXIT_USAGE" "--skill takes a skill name (dck, dck-dockerfile)" ;; esac
  local f="$DCK_ROOT/skills/$name/SKILL.md"
  [ -f "$f" ] || die "the skill file is missing from this install ($f)"
  cat "$f"
}
