# nix run .#iosdeploy -- [DEVICE_UDID] - build node-kmp's iOS app and put it on the iPad.
#
# Exists because two traps here silently produce a binary that does not contain
# the change under test, and both bit hard enough to invalidate a day of results:
#
#  - **The Xcode project runs no Gradle.** It links a prebuilt framework from
#    `monitor/build/bin/iosArm64/debugFramework`, so `xcodebuild` will happily
#    build an app around a framework that is weeks old. One was nine days stale.
#  - **Every Apple tool needs the Nix environment stripped.** `DEVELOPER_DIR` and
#    `SDKROOT` point at a Nix SDK stub, and the errors name neither Nix nor the
#    real cause - `xcrun` simply reports that Xcode is not installed.
#
# It links the framework first, prints its timestamp, then builds, installs, and
# says how to read the app's log - which is a console launch, because a println
# from Kotlin/Native reaches stdout and nothing else.
set -euo pipefail

udid="${1:-${NIXTASTIC_IPAD_UDID:-00008120-001C1D820A61A01E}}"
root="${MESHTASTIC_WORKSPACE:-$PWD}"
kmp="$root/meshtastic-node-kmp"
bundle="org.meshtastic.node.monitor"

if [ "$udid" = "-h" ] || [ "$udid" = "--help" ]; then
    cat <<'USAGE'
usage: iosdeploy [DEVICE_UDID]

  DEVICE_UDID   the iPad's UDID (default: $NIXTASTIC_IPAD_UDID, else the bench iPad)

Links monitor's iOS framework with Gradle, builds and installs the app, and
prints the command that reads its log.

Run it instead of xcodebuild. xcodebuild alone links whatever framework Gradle
last produced, with no warning when that is stale.
USAGE
    exit 0
fi

[ -d "$kmp" ] || { echo "iosdeploy: no meshtastic-node-kmp at $kmp" >&2; exit 2; }

# Strip the Nix toolchain for every Apple invocation, keeping the rest of PATH so
# java and gradle stay reachable. /usr/bin first, so xcrun resolves to Xcode's.
apple() {
    env -u DEVELOPER_DIR -u SDKROOT -u NIX_CC -u CC -u CXX -u LD -u AR -u NM -u RANLIB -u STRIP \
        PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH" "$@"
}

fw="$kmp/monitor/build/bin/iosArm64/debugFramework/Monitor.framework/Monitor"

echo "==> linking the framework (xcodebuild will not do this for you)"
( cd "$kmp" && apple ./gradlew :monitor:linkDebugFrameworkIosArm64 --quiet )
[ -f "$fw" ] || { echo "iosdeploy: no framework at $fw" >&2; exit 1; }
echo "    framework $(date -r "$fw" '+%Y-%m-%d %H:%M')"

echo "==> building the app"
( cd "$kmp/tools/monitor-ios" && apple xcodebuild \
    -project MeshMonitor.xcodeproj -scheme MeshMonitor -configuration Debug \
    -destination "platform=iOS,id=$udid" -derivedDataPath "$kmp/tools/monitor-ios/.dd" \
    build >/dev/null )

app="$kmp/tools/monitor-ios/.dd/Build/Products/Debug-iphoneos/MeshMonitor.app"
echo "==> installing"
apple xcrun devicectl device install app --device "$udid" "$app" | grep -E "bundleID|installationURL" || true

cat <<EOF

Read its log with a console launch - a println from Kotlin/Native reaches stdout
and never the unified log, and attaching to a running instance captures nothing:

  xcrun devicectl device process launch --console --terminate-existing $bundle
EOF
