#!/usr/bin/env bash
# Checks the plugin the way Omarchy and the plugin marketplace will: manifest
# schema, entry points, required files and the wording the marketplace's static
# security scan reacts to. Run it locally from the repository root:
#
#   .github/scripts/validate.sh
set -uo pipefail

fail=0
err() { echo "::error::$*"; fail=1; }

for f in manifest.json README.md LICENSE; do
  [[ -f $f ]] || err "missing required file: $f"
done
[[ -f manifest.json ]] || exit 1

jq -e . manifest.json >/dev/null 2>&1 || { err "manifest.json is not valid JSON"; exit 1; }

jq -e '.schemaVersion == 1' manifest.json >/dev/null || err "schemaVersion must be the number 1"

for field in id name version kinds entryPoints; do
  jq -e --arg f "$field" 'has($f)' manifest.json >/dev/null || err "manifest is missing '$field'"
done

id=$(jq -r '.id // ""' manifest.json)
[[ $id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $id != *..* ]] || err "invalid plugin id '$id'"
[[ $id != omarchy.* ]] || err "plugin id '$id' uses the reserved omarchy.* namespace"

version=$(jq -r '.version // ""' manifest.json)
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || err "version '$version' is not MAJOR.MINOR.PATCH"

jq -e '(.kinds | type) == "array" and (.kinds | length) > 0' manifest.json >/dev/null ||
  err "'kinds' must be a non-empty array"

# Every entry point is a safe relative path to a file that exists.
while IFS= read -r entry; do
  if [[ -z $entry || $entry == /* || $entry == *..* ]]; then
    err "unsafe entry point path: '$entry'"
  elif [[ ! -f $entry ]]; then
    err "entry point does not exist: $entry"
  fi
done < <(jq -r '.entryPoints | to_entries[] | .value' manifest.json)

if jq -e '(.kinds | index("bar-widget")) != null' manifest.json >/dev/null; then
  jq -e '.entryPoints.barWidget and .barWidget.displayName' manifest.json >/dev/null ||
    err "a bar-widget needs entryPoints.barWidget and barWidget.displayName"
fi

# Plugins are installed from a git checkout; symlinks are rejected.
if [[ -n $(find . -path ./.git -prune -o -type l -print) ]]; then
  err "symlinks are not allowed in a plugin"
fi

# The marketplace requires install and removal instructions in the README.
grep -qi '^#\+ *install' README.md || err "README needs an Install section"
grep -qi '^#\+ *remove' README.md || err "README needs a Remove section"

# The marketplace scan flags any non-negated mention of these, even in prose.
# The plugin needs neither, so keep them out of the shipped files entirely.
if hits=$(git grep -n -I -i -E '\b(sudo|pkexec)\b' -- . ':!.github' 2>/dev/null) && [[ -n $hits ]]; then
  err "privilege keywords found (the marketplace scan flags them):"$'\n'"$hits"
fi

# Shell syntax.
while IFS= read -r script; do
  bash -n "$script" || err "syntax error in $script"
done < <(git ls-files '*.sh')

if (( fail )); then
  echo "Validation failed." >&2
  exit 1
fi
echo "OK: $id $version"
