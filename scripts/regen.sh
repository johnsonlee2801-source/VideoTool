#!/bin/zsh
# Regenerate App/Info.plist (from project.yml's x-info-properties) and the Xcode project.
set -e
cd "${0:A:h:h}"
/opt/anaconda3/bin/python3 - <<'PY'
import yaml, plistlib
spec = yaml.safe_load(open("project.yml"))
with open("App/Info.plist", "wb") as f:
    plistlib.dump(spec["x-info-properties"], f, sort_keys=False)
PY
xcodegen generate --quiet "$@"
