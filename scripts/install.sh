#!/bin/zsh
# Builds SuperBasicCam in Release, copies it to /Applications, and opens it.
# System extensions load only from /Applications while SIP is enabled.
set -euo pipefail
cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if ! command -v xcodegen >/dev/null; then
  echo "xcodegen is missing. Install it with: brew install xcodegen" >&2
  exit 1
fi

xcodegen generate --quiet
xcodebuild \
  -project SuperBasicCam.xcodeproj \
  -scheme SuperBasicCam \
  -configuration Release \
  -derivedDataPath build \
  -allowProvisioningUpdates \
  -quiet \
  build

app="build/Build/Products/Release/SuperBasicCam.app"
if [[ ! -d "$app" ]]; then
  echo "Build did not produce $app" >&2
  exit 1
fi

if [[ -d /Applications/SuperBasicCam.app ]]; then
  rm -rf /Applications/SuperBasicCam.app
fi
ditto "$app" /Applications/SuperBasicCam.app
echo "Installed /Applications/SuperBasicCam.app"
open /Applications/SuperBasicCam.app
