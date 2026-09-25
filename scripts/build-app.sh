#!/bin/bash
# Build a Developer ID signed app with hardened runtime; no notarization.
set -euo pipefail

signing_identity='Developer ID Application: Ivan Kachalkin (MT228PBG67)'
configuration=release
case "${1:-}" in
    "") ;;
    --debug) configuration=debug ;;
    --help|-h)
        printf 'Usage: %s [--debug]\n' "$0"
        exit 0
        ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
esac
if (( $# > 1 )); then
    printf 'Expected at most one argument (--debug).\n' >&2
    exit 2
fi
if [[ "$(uname -s)" != Darwin ]]; then
    printf 'Clocky requires macOS and the Swift command-line tools.\n' >&2
    exit 1
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_dir="$(cd -- "$script_dir/.." && pwd -P)"
cd -- "$project_dir"

build_dir="$project_dir/build"
app_path="$build_dir/Clocky.app"
# Do not follow output symlinks or delete a directory that is not our bundle.
if [[ -L "$build_dir" || -L "$app_path" ]]; then
    printf 'Refusing a symlink at build/ or build/Clocky.app.\n' >&2
    exit 1
fi
if [[ -e "$app_path" ]]; then
    if [[ ! -d "$app_path" ]] ||
       [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist" 2>/dev/null || true)" != dev.xikxp1.clocky ]]; then
        printf 'Refusing to replace an unrecognized build/Clocky.app.\n' >&2
        exit 1
    fi
fi

/usr/bin/plutil -lint "$project_dir/Resources/Info.plist"
swift build --configuration "$configuration" --product Clocky
bin_dir="$(swift build --configuration "$configuration" --product Clocky --show-bin-path)"
if [[ ! -x "$bin_dir/Clocky" ]]; then
    printf 'Built Clocky executable not found at %s\n' "$bin_dir" >&2
    exit 1
fi

mkdir -p -- "$build_dir"
staging="$(mktemp -d "$build_dir/.clocky-package.XXXXXX")"
# Only the private directory returned by mktemp is removed during cleanup.
trap 'rm -rf -- "$staging"' EXIT
bundle="$staging/Clocky.app"
mkdir -p -- "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp -- "$bin_dir/Clocky" "$bundle/Contents/MacOS/Clocky"
chmod 755 "$bundle/Contents/MacOS/Clocky"
cp -- "$project_dir/Resources/Info.plist" "$bundle/Contents/Info.plist"
cp -- "$project_dir/Resources/AppIcon.icns" "$bundle/Contents/Resources/AppIcon.icns"
/usr/bin/plutil -lint "$bundle/Contents/Info.plist"
/usr/bin/codesign --force --sign "$signing_identity" --options runtime --timestamp "$bundle"
/usr/bin/codesign --verify --strict --verbose=2 "$bundle"

# Replacement is restricted to the fixed, checked generated bundle above.
# Keep the previous app until the new bundle has built and passed validation.
rm -rf -- "$app_path"
mv -- "$bundle" "$app_path"
printf '\nBuilt %s (%s, Developer ID signed with hardened runtime and secure timestamp; not notarized).\n' "$app_path" "$configuration"
