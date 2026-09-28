# Matter for Threads 0.1.0

Matter 0.1.0 is the first stable release of Matter for Threads. It is based on the v0.1.0-30 implementation validated against Threads 448.0.0 on arm64, primarily with LiveContainer; direct sideload testing has also been performed. Compatibility with other Threads versions is not guaranteed.

## Included

- Block Sponsored Posts, enabled by default.
- Block Ad Telemetry and Block Analytics for the confirmed Threads 448.0.0 entry points currently covered by Matter; both are off by default.
- Cache Size, Clear Cache, and optional Clear Cache on Startup; startup clearing is off by default.
- Matter settings integration in Threads.
- Debug Logging, off by default.
- LiveContainer-aware temporary-cache validation that proves the temporary directory matches the validated container alias before operating on it.

## Compatibility and scope

Privacy controls cover only the confirmed entry points currently implemented by Matter; they do not block all Meta telemetry or analytics. Cache management is limited to validated cache locations and shared `NSURLCache` responses. Matter does not clear account or session data. Compatibility with Threads versions other than 448.0.0 is not guaranteed.
