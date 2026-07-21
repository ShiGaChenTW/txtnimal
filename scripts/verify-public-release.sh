#!/bin/zsh
set -euo pipefail

app_path=${1:-.build/DerivedData/Build/Products/Release/txtnimal.app}
if [[ ! -d "$app_path" ]]; then
  print -u2 "release app not found: $app_path"
  exit 2
fi

identity=$(codesign -dv --verbose=4 "$app_path" 2>&1 | awk -F= '/^Authority=Developer ID Application/ {print $2; exit}')
if [[ -z "$identity" || "$identity" == "-" ]]; then
  print -u2 "public release requires Developer ID signing; ad-hoc/development signing rejected"
  exit 3
fi

codesign --verify --deep --strict --verbose=2 "$app_path"
spctl --assess --type execute --verbose=2 "$app_path"
xcrun stapler validate "$app_path"
print "PUBLIC_RELEASE_GATE_PASSED"
