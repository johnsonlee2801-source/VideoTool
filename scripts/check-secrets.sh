#!/bin/zsh
# Refuses to let secrets or personal data reach the (future public) repo.
#   scripts/check-secrets.sh            scan tracked files (working tree)
#   scripts/check-secrets.sh --history  scan every commit on local branches and tags
# Generic patterns live here. Personal identifiers (names, emails, local paths,
# team IDs) go one per line in .git/info/secret-patterns, which is never pushed.
# Exit 1 on any finding. Installed as a pre-push hook by scripts/install-hooks.sh.
set -u
cd "${0:A:h:h}"

generic=(
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
  'AKIA[0-9A-Z]{16}'
  'gh[pousr]_[A-Za-z0-9]{30,}'
  'github_pat_[A-Za-z0-9_]{30,}'
  'sk-[A-Za-z0-9_-]{24,}'
  'sk-ant-[A-Za-z0-9_-]{20,}'
  'xox[abprs]-[A-Za-z0-9-]{10,}'
  'AIza[0-9A-Za-z_-]{35}'
  '(api[_-]?key|secret|password|passwd|token)[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"'[:space:]]{8,}'
)
personal=()
if [[ -f .git/info/secret-patterns ]]; then
  while IFS= read -r line; do [[ -n "$line" && "$line" != \#* ]] && personal+=("$line"); done < .git/info/secret-patterns
fi
# Files that must never be committed, whatever they contain.
forbidden='(^|/)(\.env(\..*)?|.*\.(p12|pem|key|mobileprovision|cer|sqlite|sqlite-wal|sqlite-shm|log)|watch_later/.*|\.DS_Store)$'
self='scripts/check-secrets.sh'

pattern=$(printf '%s|' "${generic[@]}" "${personal[@]}"); pattern=${pattern%|}
found=0
report() { print -u2 "✗ $1"; found=1; }

if [[ "${1:-}" == "--history" ]]; then
  for c in $(git rev-list --branches --tags); do   # what can be pushed (not remote-tracking refs)
    git ls-tree -r --name-only "$c" | grep -E "$forbidden" | while read -r f; do report "commit ${c:0:7}: forbidden file $f"; done
    hits=$(git grep -I -n -E -e "$pattern" "$c" -- . ":(exclude)$self" 2>/dev/null | head -5)
    [[ -n "$hits" ]] && report "commit ${c:0:7}:\n$hits"
    for meta in "$(git log -1 --format='%an <%ae> | %cn <%ce> | %B' "$c")"; do
      [[ ${#personal[@]} -gt 0 ]] && print -r -- "$meta" | grep -q -E "$(printf '%s|' "${personal[@]}" | sed 's/|$//')" \
        && report "commit ${c:0:7}: personal data in author/committer/message"
    done
  done
else
  git ls-files | grep -E "$forbidden" | while read -r f; do report "forbidden file tracked: $f"; done
  hits=$(git grep -I -n -E -e "$pattern" -- . ":(exclude)$self" 2>/dev/null)
  [[ -n "$hits" ]] && report "secret or personal data in tracked files:\n$hits"
fi

if [[ $found -eq 0 ]]; then print "✓ no secrets or personal data found (${#generic[@]} generic + ${#personal[@]} personal patterns)"; fi
exit $found
