#!/usr/bin/env bash
#
# scripts/check-public-hygiene.sh — public-repository hygiene (ecosystem standard A3, S3).
#
#   bash scripts/check-public-hygiene.sh            every tracked file (vendored .agents/skills/ excluded)
#   bash scripts/check-public-hygiene.sh FILE...    only these files
#
# Fails (exit 1) on content a public repository must not carry:
#   personal-path    /Users/<name>, /home/<name> (the product's container users are allowed)
#   private-org      the private GitHub organisation
#   private-repo     private repository names
#   internal-tool    internal tooling and mesh names
#   email            @dailybot.com addresses other than security@, support@, ops@, conduct@
#   secret-*         AWS, GitHub, OpenAI, Anthropic, Slack, Google keys; private-key headers;
#                    quoted secret assignments of 16+ characters
#
# Findings print the file, line and rule — never the matched text, so a real secret is not
# echoed into CI logs. Exceptions live in .public-hygiene-allow, one per line:
#   <path glob> <rule|*> <reason...>
# and are only for obviously fake fixtures (containing fake, test, planted or example).
# bash 3.2 + grep -E; no network. Patterns are written so this file never matches itself.

set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT" || exit 2
ALLOW_FILE="${HYGIENE_ALLOW_FILE:-.public-hygiene-allow}"

# Container users of this product (paths like /home/dev/... are product paths, not personal).
ALLOWED_HOME_USERS="dev builder runner"

# rule<TAB>extended regex. B = a non-word boundary usable by BSD and GNU grep.
B='(^|[^A-Za-z0-9_-])'
RULES="$(cat <<EOF
personal-path	/Users/[A-Za-z][A-Za-z0-9._-]*
personal-path	/home/[a-z][a-z0-9._-]*
private-org	[Dd]aily[Bb]ot-In[c]
private-repo	${B}(dailybot-cor[e]|coding-agent-host-ki[t]|dailybot-private-skill[s]|api-service[s]|chatbot-function[s]|discord-gatewa[y]|msteams-app-manifest[o]|labs-project[s])([^A-Za-z0-9_-]|$)
internal-tool	${B}(dbde[v]|dailybot-de[v]|dailybot-peer[s]|dailybot-workspace[s])([^A-Za-z0-9_-]|$)
internal-tool	dailybot-w[s]-|\[dailybot-mes[h]\]
email	[A-Za-z0-9._%+-]+@dailybot\.co[m]
secret-aws	(AKI[A]|ASI[A])[0-9A-Z]{16}
secret-github	(gh[pousr]_[A-Za-z0-9]{36,}|github_pa[t]_[A-Za-z0-9_]{22,})
secret-openai	sk-(pro[j]-)?[A-Za-z0-9]{32,}
secret-anthropic	sk-an[t]-[A-Za-z0-9_-]{20,}
secret-slack	xo[x][baprs]-[A-Za-z0-9-]{10,}
secret-google	AIz[a][0-9A-Za-z_-]{35}
private-key	-----BEGIN [A-Z ]*PRIVATE KE[Y]-----
quoted-secret	([Kk][Ee][Yy]|[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd])[A-Za-z0-9_]*["']?[[:space:]]*[:=][[:space:]]*["'][A-Za-z0-9_+/=.-]{16,}["']
EOF
)"

allowed() {  # allowed <path> <rule> — true when .public-hygiene-allow covers it
  local path="$1" rule="$2" g r rest
  [ -f "$ALLOW_FILE" ] || return 1
  while read -r g r rest; do
    case "$g" in ''|'#'*) continue ;; esac
    # shellcheck disable=SC2254  # the glob is the point
    case "$path" in $g) ;; *) continue ;; esac
    [ "$r" = "*" ] || [ "$r" = "$rule" ] || continue
    return 0
  done < "$ALLOW_FILE"
  return 1
}

# Line content is filtered for the two rules that have legitimate forms.
legit() {  # legit <rule> <line> — true when the match is an allowed form
  local rule="$1" line="$2" m u
  case "$rule" in
    personal-path)
      # every /home/<user> on the line must be an allowed container user, and no /Users/
      case "$line" in */Users/*) return 1 ;; esac
      for m in $(printf '%s\n' "$line" | grep -oE '/home/[a-z][a-z0-9._-]*'); do
        u="${m#/home/}"
        case " $ALLOWED_HOME_USERS " in *" $u "*) ;; *) return 1 ;; esac
      done
      return 0 ;;
    email)
      for m in $(printf '%s\n' "$line" | grep -oE '[A-Za-z0-9._%+-]+@dailybot\.co[m]'); do
        case "${m%@*}" in security|support|ops|conduct) ;; *) return 1 ;; esac
      done
      return 0 ;;
  esac
  return 1
}

FILES=()
if [ $# -gt 0 ]; then
  FILES=("$@")
else
  while IFS= read -r -d '' f; do
    case "$f" in .agents/skills/*) continue ;; esac   # vendored, pinned copies
    FILES+=("$f")
  done < <(git ls-files -z)
fi

findings=0
checked=0
for f in ${FILES[@]+"${FILES[@]}"}; do
  [ -f "$f" ] && [ ! -L "$f" ] || continue
  # binary files are skipped (grep -I)
  checked=$((checked + 1))
  while IFS="$(printf '\t')" read -r rule regex; do
    [ -n "$rule" ] || continue
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      lineno="${hit%%:*}"
      content="${hit#*:}"
      if legit "$rule" "$content"; then continue; fi
      if allowed "$f" "$rule"; then continue; fi
      printf '%s:%s: [%s] public hygiene violation (content not shown)\n' "$f" "$lineno" "$rule"
      findings=$((findings + 1))
    done < <(grep -InE -- "$regex" "$f" 2>/dev/null || true)
  done <<EOF
$RULES
EOF
done

if [ "$findings" -gt 0 ]; then
  printf 'public hygiene: %d finding(s) in %d file(s) checked — fix them, or list an obviously fake fixture in %s with a reason\n' "$findings" "$checked" "$ALLOW_FILE" >&2
  exit 1
fi
printf 'public hygiene: %d file(s) checked, no finding\n' "$checked"
