# Install Model Quota

Model Quota has not been notarized by Apple and is not signed with a
Developer ID certificate. macOS may block it when you first open it.
Continue only if you trust this project and the source of your download.

## Before you start

You need macOS 14 or later and the official Codex CLI or Antigravity (`agy`) CLI.
Sign in via `codex login` or `agy` in Terminal. Model Quota uses those existing logins.

The current prebuilt release is for Apple Silicon Macs. It has been tested on
macOS 27 with the native Homebrew Codex CLI 0.155.0 and agy. Older supported macOS
versions and npm wrappers have not been verified. Use a native executable;
a wrapper that depends on a shell-specific Node.js PATH may fail at login.

## Install and open

1. Extract the download and move **Model Quota.app** to Applications.
2. Double-click the app. If macOS says it cannot verify the developer or
   check the app, dismiss the alert.
3. Open System Settings, then Privacy & Security. In the Security section,
   select Open Anyway for Model Quota.
4. Confirm with Open and authenticate if macOS asks you to.

After macOS accepts the app as an exception, you can open it normally.
Look for Model Quota in the menu bar; it does not appear in the Dock.

This exception does not notarize the app. If Open Anyway is unavailable,
or macOS reports malware, damage, or tampering, stop and contact the
project maintainer or your Mac administrator.

See [Apple’s official instructions](https://support.apple.com/en-us/102445).

## Using Model Quota

Click the menu bar item to see usage details. Open Settings to configure
executable paths if automatic detection cannot find them. The app version
appears below the Model Quota name in Settings.

To open the app automatically when you sign in to your Mac, enable
**Settings → General → Launch at Login** after moving the app to its final
location. This setting takes effect immediately.
