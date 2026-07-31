# SPDX-FileCopyrightText: 2026 James Rich
# SPDX-License-Identifier: GPL-3.0-only
#
# nix run .#bootstrap-sdk — reconcile $ANDROID_HOME against
# android-sdk-packages.txt: the SDK stays writable (AGP insists) but its
# contents are declared. The flake exports NIXTASTIC_JDK and puts the
# android CLI on PATH where nixpkgs carries it.

root="${MESHTASTIC_WORKSPACE:-$PWD}"
sdk="${ANDROID_HOME:-$HOME/Android/Sdk}"
list="$root/android-sdk-packages.txt"

[ -f "$list" ] || { echo "missing $list"; exit 1; }

if ! command -v android >/dev/null; then
  echo "android CLI unavailable on this platform"
  echo "(nixpkgs ships it for x86_64-linux and aarch64-darwin only)"
  echo "Fall back to: sdkmanager --sdk_root=$sdk --install ..."
  exit 1
fi

# sdkmanager underneath android-cli still needs a JDK; take
# it from Nix rather than whatever is on the host PATH.
export JAVA_HOME="$NIXTASTIC_JDK"

want=()
while read -r line; do
  case "$line" in ""|\#*) continue ;; esac
  want+=("$line")
done < "$list"

echo "sdk:      $sdk"
echo "cli:      $(android --version)"
echo "packages: ${#want[@]} declared in $list"
echo ""
android --sdk="$sdk" sdk install "${want[@]}"
echo ""
android --sdk="$sdk" sdk list

