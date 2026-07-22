#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
version_file="$project_root/VERSION"

if [[ ! -f "$version_file" ]]; then
  print -u2 "error: VERSION file not found"
  exit 2
fi

version=${1:-$(<"$version_file")}
version=${version//[[:space:]]/}
if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  print -u2 "error: invalid version: $version"
  exit 2
fi

build_root="$project_root/.build/package-v$version"
derived_data="$build_root/DerivedData"
output_dir="$build_root/output"
app_name="txtnimal.app"
app_path="$output_dir/$app_name"
dmg_path="$output_dir/txtnimal-v$version-macos-universal.dmg"
checksum_path="$dmg_path.sha256"
dmg_stage=$(mktemp -d /tmp/txtnimal-dmg.XXXXXX)

cleanup() {
  if [[ "$dmg_stage" == /tmp/txtnimal-dmg.* && -d "$dmg_stage" ]]; then
    rm -rf "$dmg_stage"
  fi
}
trap cleanup EXIT

mkdir -p "$output_dir"

print "Building txtnimal v$version for arm64 and x86_64..."
xcodebuild \
  -project "$project_root/txtnimal.xcodeproj" \
  -scheme txtnimal \
  -configuration Release \
  -derivedDataPath "$derived_data" \
  -destination 'generic/platform=macOS' \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$version" \
  build CODE_SIGNING_ALLOWED=NO

built_app="$derived_data/Build/Products/Release/$app_name"
if [[ ! -d "$built_app" ]]; then
  print -u2 "error: build completed without $built_app"
  exit 3
fi

if [[ "$app_path" != "$project_root"/.build/package-v*/output/txtnimal.app ]]; then
  print -u2 "error: refusing to replace unexpected app path: $app_path"
  exit 3
fi
rm -rf "$app_path"
ditto "$built_app" "$app_path"

# Self-use release: preserve bundle integrity with an ad-hoc signature. This is
# intentionally not a Developer ID signature and does not imply notarization.
codesign --force --deep --sign - "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"

for executable in \
  "$app_path/Contents/MacOS/txtnimal" \
  "$app_path/Contents/XPCServices/PluginRunnerSpikeService.xpc/Contents/MacOS/PluginRunnerSpikeService" \
  "$app_path/Contents/XPCServices/PluginRunnerSpikeService.xpc/Contents/Resources/PluginRunnerSpikeWorker.app/Contents/MacOS/PluginRunnerSpikeWorker"
do
  actual_architectures=$(lipo -archs "$executable")
  if [[ " $actual_architectures " != *" arm64 "* || " $actual_architectures " != *" x86_64 "* ]]; then
    print -u2 "error: missing universal architectures in $executable ($actual_architectures)"
    exit 4
  fi
done

ditto "$app_path" "$dmg_stage/$app_name"
ln -s /Applications "$dmg_stage/Applications"

hdiutil create \
  -volname "txtnimal $version" \
  -srcfolder "$dmg_stage" \
  -format UDZO \
  -ov \
  "$dmg_path"
hdiutil verify "$dmg_path"

(
  cd "$output_dir"
  shasum -a 256 "${dmg_path:t}" > "${checksum_path:t}"
)

print "PACKAGE_SUCCEEDED"
print "app=$app_path"
print "dmg=$dmg_path"
print "checksum=$checksum_path"
print "warning=ad-hoc signed and not notarized"
