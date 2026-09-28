# Matter for Threads 0.1.0 RC1 runtime notes

Matter 0.1.0 RC1 is based on the v0.1.0-30 implementation validated on arm64 Threads 448.0.0, primarily under LiveContainer; direct sideload testing has also been performed. Other app versions are not guaranteed.

## First-install defaults

- Block Sponsored Posts: ON
- Block Ad Telemetry: OFF
- Block Analytics: OFF
- Clear Cache on Startup: OFF
- Debug Logging: OFF

Unset values use `NSUserDefaults` registered defaults. Existing stored values are not overwritten. RC1's one-time preference migration copies an old `com.example.matter.*` value only when its corresponding `com.panaikran.matter.*` value is absent, then records a migration marker. The old values are retained; all future Matter reads and writes use the new keys.

## Sponsored-post filtering

The optional filter runs after the original sponsored-item preparation callback. It is compiled only when `MATTER_EXPERIMENTAL_FILTERING=1` and is active only when Block Sponsored Posts is ON. It uses strict sponsored-item identification and fails open when inputs or results are unknown or unsafe. The relevant implementation is in `Tweak.xm`.

## Privacy callbacks

Block Ad Telemetry and Block Analytics independently gate the four runtime-confirmed methods documented in [telemetry scope](threads-448.0-telemetry-analysis.md). Signature mismatches leave Threads behavior unchanged. The optional telemetry discovery hooks are compiled only when `MATTER_TELEMETRY_DISCOVERY=1`; release builds use `0`.

## Matter Settings entry

The host Settings screen is `BCNSettings.BCNSettingsViewController`, which owns the verified `IGListAdapter` data source. When enabled, Matter adds one diffable marker to a copy of the known six-object top-level list, then provides its own section controller, UIKit cell, and settings navigation. The marker is inserted after the second separator and before the two footer labels. Matter does not alter the 14 native IGDS rows or construct private IGDS row models. Unexpected collection layouts or runtime signatures fail open. `MATTER_SETTINGS_INJECTION` defaults to `0` in builds unless explicitly enabled.

## Cache and settings screen

Cache roots, startup behavior, and privacy boundaries are summarized in [cache management notes](threads-448.0-cache-management.md). About displays the build's Matter version and the host app's `CFBundleShortVersionString` as “Threads version.”

## Build switches

The public RC1 build uses:

```sh
MATTER_EXPERIMENTAL_FILTERING=1
MATTER_SETTINGS_INJECTION=1
MATTER_UI_DISCOVERY=0
MATTER_TELEMETRY_DISCOVERY=0
PACKAGE_VERSION='0.1.0~rc1'
```

`TweakUI.xm` is excluded when `MATTER_UI_DISCOVERY=0`. The normal production privacy hooks are independent of telemetry discovery mode.
