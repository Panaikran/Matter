# Matter for Threads

Matter over Threads.

An independent open-source tweak that adds content controls, privacy controls, cache management, and quality-of-life features to Threads.

Matter for Threads is an independent open-source project and is not affiliated with, endorsed by, or sponsored by Meta. Threads is a trademark/software product of Meta. This repository does not distribute proprietary Threads binaries or assets.

## Features

**Content**

- Block Sponsored Posts

**Privacy**

- Block Ad Telemetry
- Block Analytics

**Cache**

- Cache Size
- Clear Cache
- Clear Cache on Startup

**Advanced**

- Debug Logging

## Compatibility

- Validated against Threads 448.0.0 on arm64.
- Tested primarily with LiveContainer; direct sideload testing has also been performed.
- Other Threads versions are not guaranteed. Threads internal classes and selectors can change.

## First-install defaults

| Setting | Default |
| --- | --- |
| Block Sponsored Posts | ON |
| Block Ad Telemetry | OFF |
| Block Analytics | OFF |
| Clear Cache on Startup | OFF |
| Debug Logging | OFF |

Sponsored-post blocking is ON as Matter's primary visible feature. Privacy blocking remains available, but those hooks alter Threads behavior and cover only confirmed Threads 448.0.0 entry points; users opt in by enabling them. Automatic cache clearing is OFF because Threads may need to download cached media again, using additional network data and battery. Debug Logging is OFF to avoid routine diagnostics and log activity.

When upgrading from RC1 builds that used the `com.example.matter` package and `com.example.matter.*` preference keys, the new package replaces the old package. Matter copies each existing preference to its `com.panaikran.matter.*` key once. An existing value in the new namespace always takes precedence. Old keys are left in place, and subsequent reads and writes use the new namespace. Unset preferences keep the defaults above.

## Installation

Build Matter from this repository and install or inject the resulting Matter package using a compatible Theos package/injection environment for your own Threads installation. This repository distributes Matter source only; it does not distribute Threads or decrypted Meta software.

## Building

Build on a supported Theos environment with the iOS SDK and arm64 toolchain installed. Build Matter 0.1.0 with:

```sh
export THEOS="$HOME/theos"
export THEOS_STAGING_DIR="$HOME/.cache/theos/Matter/staging"

make clean package \
  MATTER_EXPERIMENTAL_FILTERING=1 \
  MATTER_SETTINGS_INJECTION=1 \
  MATTER_UI_DISCOVERY=0 \
  MATTER_TELEMETRY_DISCOVERY=0 \
  PACKAGE_VERSION='0.1.0'
```

The package is arm64 (`iphoneos-arm`) and is named `com.panaikran.matter_0.1.0_iphoneos-arm.deb`.

The Git tag is `v0.1.0`, and the GitHub Release title is **Matter for Threads 0.1.0**. The About screen displays `0.1.0`. See [release notes](RELEASE_NOTES.md).

## Privacy scope

Block Ad Telemetry suppresses the confirmed Threads 448.0.0 `IGAdPlatformLogger_objc` sponsored-delivery and insertion-success callbacks covered by Matter. Block Analytics suppresses the confirmed `IGApplicationAnalytics` `logEvent:` and `logEventImmediately:` entry points covered by Matter. These controls do not block all Meta telemetry, all analytics, or general network traffic. Their defaults are OFF.

## Cache management

Matter measures files under the running app's dynamically resolved `NSCachesDirectory` and validated `NSTemporaryDirectory()` scope. Cache Size represents Matter's safely clearable cache scope, not total Threads application storage; it does not separately estimate shared `NSURLCache` responses. Clear Cache removes children inside accepted cache roots, preserves the roots, and clears shared `NSURLCache` responses. Clear Cache on Startup defaults OFF and runs once per new Threads process when enabled.

The LiveContainer cache resolver derives a trusted container anchor from `NSCachesDirectory`. It accepts the temporary directory only when it proves equivalence with the container's expected `tmp` alias, then operates on the canonical actual temporary directory. Child symlinks are skipped. Matter never clears Documents, Application Support, Preferences, Cookies, account/session data, Keychain items, drafts, downloaded documents, or other Library directories. Cache Size may differ from iOS Storage settings because its scope is intentionally limited.

## Debugging

Debug Logging defaults OFF. When enabled, Matter logs use these prefixes:

- `[Matter]`
- `[Matter:UI]`
- `[Matter:Telemetry]`
- `[Matter:Privacy]`
- `[Matter:Cache]`

For example, in PowerShell:

```powershell
.\idevicesyslog.exe | Select-String -SimpleMatch "[Matter]"
```

Before sharing logs, remove usernames, IDs, tokens, private content, filesystem paths, and other personal information.

## Known limitations

- Compatibility is currently validated against Threads 448.0.0; other versions are not guaranteed.
- Threads internal classes and selectors can change.
- Privacy blockers cover specific confirmed entry points, not every possible Meta analytics or telemetry mechanism.
- LiveContainer has unusual container/tmp alias behavior handled by Matter's validated cache resolver.
- Sideloaded builds may encounter signing/keychain differences unrelated to Matter.

## License

Matter's original source code is MIT licensed. This license does not cover Threads, Meta binaries or assets, or third-party components; their respective owners' terms apply. See [LICENSE](LICENSE).
