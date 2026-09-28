# Threads 448.0.0 telemetry and analytics scope

This note records runtime-confirmed Matter hook coverage for Threads 448.0.0. It is not a claim to describe every Meta telemetry or analytics mechanism.

## Confirmed ad telemetry callbacks

Matter's Block Ad Telemetry preference gates only these `IGAdPlatformLogger_objc` void methods:

- `logDeliveryEventForSponsoredItems:containerModule:surfaceExtraLoggingDicts:isPrefetch:deliveryContext:recentSeenItemIDs:surfaceSnapshot:perfLoggingDict:extraLoggingDict:`
- `logInsertionSuccessForSponsoredItem:containerModule:insertedPosition:surfaceExtraLoggingDict:surfaceSnapshot:perfLoggingDict:`

Both were observed during sponsored-feed processing. When the preference is OFF, Matter forwards every argument to the original method once. When ON, Matter skips only these methods; it does not block sponsored content or general networking.

## Confirmed general analytics callbacks

Matter's independent Block Analytics preference gates only these `IGApplicationAnalytics` void methods:

- `logEvent:`
- `logEventImmediately:`

Both were observed at runtime. When OFF, each original is called once with the original event object. When ON, Matter skips these entry points without reading or logging the event.

## Unconfirmed candidate and safeguards

`IGAdInsertionMediaViewTracker -trackViewpointActionForMediaView:...` was identified and its discovery hook installed, but runtime firing was not confirmed. It is not blocked. Discovery mode defaults OFF.

Production hook installation checks the exact class, selector, return type, argument count, object/scalar positions, and scalar sizes. A missing or mismatched method is left untouched. Debug logs identify only the category, class, selector, and coarse suppression count; payloads and identifiers are not inspected or logged.

Coverage is specific to confirmed Threads 448.0.0 entry points currently covered by Matter. It does not mean that all Meta telemetry, analytics, or tracking is blocked.
