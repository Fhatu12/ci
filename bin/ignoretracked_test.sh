#!/usr/bin/env bash
# ignoretracked_test.sh — pin both refusal and allowance behavior for
# bin/ignoretracked. Offline and deterministic: disposable local repos only.
set -uo pipefail

BIN=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ignoretracked
tmpRoot=$(mktemp -d)
trap 'rm -rf "$tmpRoot"' EXIT
pass=0
fail=0
output=
status=0

newRepo() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email dev@hanzo.ai
  git -C "$dir" config user.name "Hanzo Dev"
  git -C "$dir" config core.hooksPath /dev/null
  printf 'tracked\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" commit -qm "initial"
}

runGate() {
  local dir=$1
  shift
  output=
  status=0
  if [ "$#" -gt 0 ]; then
    output=$(env "$@" "$BIN" "$dir" 2>&1) || status=$?
  else
    output=$("$BIN" "$dir" 2>&1) || status=$?
  fi
}

ok() {
  pass=$((pass + 1))
  echo "  ok    $1"
}

notOk() {
  fail=$((fail + 1))
  echo "  FAIL  $1" >&2
  echo "        $2" >&2
  if [ -n "$output" ]; then
    printf '        output: %s\n' "$output" >&2
  fi
}

echo "CLEAN AND OUT-OF-SCOPE DIRECTORIES"

nonRepo="$tmpRoot/non-repo"
mkdir -p "$nonRepo"
runGate "$nonRepo"
if [ "$status" -eq 0 ] && [ -z "$output" ]; then
  ok "directory outside a Git repository exits 0"
else
  notOk "directory outside a Git repository exits 0" \
    "expected rc=0 and no output, got rc=$status"
fi

missing="$tmpRoot/missing"
runGate "$missing"
if [ "$status" -eq 1 ] && grep -Fq -- "ignoretracked: no such directory: $missing" <<<"$output"; then
  ok "missing directory exits 1 with a useful diagnostic"
else
  notOk "missing directory exits 1 with a useful diagnostic" \
    "expected rc=1 and the missing path, got rc=$status"
fi

cleanRepo="$tmpRoot/clean"
newRepo "$cleanRepo"
printf 'build/\n' > "$cleanRepo/.gitignore"
git -C "$cleanRepo" add .gitignore
git -C "$cleanRepo" commit -qm "ignore build output"
runGate "$cleanRepo"
if [ "$status" -eq 0 ] && grep -Fq -- \
  "ignoretracked: OK — nothing tracked that .gitignore ignores" <<<"$output"; then
  ok "clean repository prints the clean-state message and exits 0"
else
  notOk "clean repository prints the clean-state message and exits 0" \
    "expected rc=0 and the documented clean-state message, got rc=$status"
fi

allowRepo="$tmpRoot/allow"
newRepo "$allowRepo"
mkdir -p "$allowRepo/src" "$allowRepo/cache"
printf 'cache/\n' > "$allowRepo/.gitignore"
printf 'normal source\n' > "$allowRepo/src/main.txt"
printf 'ignored runtime data\n' > "$allowRepo/cache/runtime.tmp"
git -C "$allowRepo" add .gitignore src/main.txt
git -C "$allowRepo" commit -qm "track normal source"
runGate "$allowRepo"
if [ "$status" -eq 0 ] && grep -Fq -- \
  "ignoretracked: OK — nothing tracked that .gitignore ignores" <<<"$output"; then
  ok "normal tracked files and ignored untracked files do not false-positive"
else
  notOk "normal tracked files and ignored untracked files do not false-positive" \
    "expected rc=0 and no tracked-ignore finding, got rc=$status"
fi

echo
echo "TRACKED CONTENT MATCHED BY .gitignore"

blockedRepo="$tmpRoot/blocked"
newRepo "$blockedRepo"
mkdir -p "$blockedRepo/build"
printf 'build/\n' > "$blockedRepo/.gitignore"
dd if=/dev/zero of="$blockedRepo/build/artifact.bin" bs=1048576 count=2 2>/dev/null
git -C "$blockedRepo" add .gitignore
git -C "$blockedRepo" add -f build/artifact.bin
git -C "$blockedRepo" commit -qm "force-add ignored artifact"

if git -C "$blockedRepo" ls-files --error-unmatch build/artifact.bin >/dev/null 2>&1 \
  && git -C "$blockedRepo" check-ignore --no-index -q build/artifact.bin; then
  ok "fixture is force-tracked while still matched by .gitignore"
else
  output=
  notOk "fixture is force-tracked while still matched by .gitignore" \
    "fixture did not represent the production failure shape"
fi

runGate "$blockedRepo" IGNORETRACKED_MAX_MB=1
if [ "$status" -eq 1 ] \
  && grep -Fq -- "::error::" <<<"$output" \
  && grep -Fq -- "over the 1 MB ceiling" <<<"$output"; then
  ok "2 MiB ignored-and-tracked content exceeds a 1 MB ceiling"
else
  notOk "2 MiB ignored-and-tracked content exceeds a 1 MB ceiling" \
    "expected rc=1, ::error::, and the configured ceiling, got rc=$status"
fi

runGate "$blockedRepo"
if [ "$status" -eq 0 ] \
  && grep -Fq -- "ignoretracked: 1 tracked file(s), 2.0 MB" <<<"$output" \
  && grep -Fq -- "ignoretracked: OK — 2.0 MB is under the 100 MB ceiling" <<<"$output"; then
  ok "the same repository passes under the default ceiling and reports size"
else
  notOk "the same repository passes under the default ceiling and reports size" \
    "expected rc=0 and the 2.0 MB/default-ceiling report, got rc=$status"
fi

if grep -Fq -- ".gitignore:1:build/" <<<"$output"; then
  ok "by-rule report identifies the exact .gitignore source line"
else
  notOk "by-rule report identifies the exact .gitignore source line" \
    "expected .gitignore:1:build/ in the report"
fi

echo
echo "ignoretracked_test: $pass passed, $fail failed"
if [ "$fail" -ne 0 ]; then
  echo "ignoretracked_test: failure — see diagnostics above" >&2
  exit 1
fi
