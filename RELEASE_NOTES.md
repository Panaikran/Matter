# Matter for Threads 0.1.0 RC1

**Release candidate** prepared for the planned `v0.1.0-rc1` tag. The Debian package version is `0.1.0~rc1`; the planned GitHub Release title is **Matter for Threads 0.1.0 RC1**. This candidate is based on the v0.1.0-30 implementation validated with Threads 448.0.0, primarily under LiveContainer, with direct sideload testing also performed.

## Included

- Sponsored-post blocking, enabled by default.
- Separate ad-telemetry and analytics controls for confirmed Threads 448.0.0 entry points; both are off by default.
- Cache size display, confirmed manual cache clearing, and optional once-per-process-start cache clearing; automatic clearing is off by default.
- A Matter-owned entry in Threads Settings and a Matter-owned settings screen.
- Debug logging, off by default.
- LiveContainer-aware temporary-cache validation that proves the temporary directory matches the validated container alias before operating on it.

## Scope

The privacy controls cover specific confirmed callbacks, not all Meta telemetry or analytics. Compatibility with other Threads versions is not guaranteed. This is a release candidate, not a claim of final or universal compatibility.
