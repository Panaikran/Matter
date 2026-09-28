# Threads 448.0.0 compatibility notes

Matter for Threads 0.1.0 is validated against Threads 448.0.0 (build 1071656538), arm64. The executable and app bundle used during local analysis are not part of this repository. Compatibility with other Threads versions is not guaranteed.

Static Objective-C/Swift metadata and runtime observations helped identify the sponsored-feed insertion path and the Settings screen's IGList integration. These findings are limited to this version and are not a complete model of Threads internals.

The feed integration includes `BCNMainFeedAdsAwareDataSource`, `BCNMainFeedAdsInsertionDataSource`, `BCNMainFeedAdsInsertionSurfaceHandler`, and sponsored-item metadata types. Names alone were not treated as proof of behavior; the active filter was selected from runtime evidence and remains fail-open on unknown input.

See [runtime notes](threads-448.0-runtime.md), [cache notes](threads-448.0-cache-management.md), and [telemetry scope](threads-448.0-telemetry-analysis.md) for the current Matter integration. No proprietary app files, binary dumps, copied assets, or user data belong in this repository.
