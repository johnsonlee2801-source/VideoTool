#!/bin/zsh
# Installs a local pre-push hook that runs the secret check on the working tree
# and on full history. Hooks live in .git/hooks and are not pushed.
set -e
cd "${0:A:h:h}"
cat > .git/hooks/pre-push <<'HOOK'
#!/bin/zsh
repo="$(git rev-parse --show-toplevel)"
"$repo/scripts/check-secrets.sh" && "$repo/scripts/check-secrets.sh" --history || {
  print -u2 "pre-push: blocked. Remove the data above (and rewrite history if it was committed)."
  exit 1
}
HOOK
chmod +x .git/hooks/pre-push
[[ -f .git/info/secret-patterns ]] || print "# one regex per line: names, emails, local paths, team IDs (never pushed)" > .git/info/secret-patterns
print "pre-push hook installed; personal patterns: .git/info/secret-patterns"
