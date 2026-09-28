#import <Foundation/Foundation.h>

#ifndef MATTER_DEBUG_LOGGING
#define MATTER_DEBUG_LOGGING 1
#endif

FOUNDATION_EXPORT BOOL MatterBlockSponsoredPostsEnabled(void);
FOUNDATION_EXPORT BOOL MatterBlockAdTelemetryEnabled(void);
FOUNDATION_EXPORT BOOL MatterBlockAnalyticsEnabled(void);
FOUNDATION_EXPORT BOOL MatterDebugLoggingEnabled(void);
FOUNDATION_EXPORT BOOL MatterClearCacheOnStartupEnabled(void);

FOUNDATION_EXPORT void MatterSetBlockSponsoredPostsEnabled(BOOL enabled);
FOUNDATION_EXPORT void MatterSetBlockAdTelemetryEnabled(BOOL enabled);
FOUNDATION_EXPORT void MatterSetBlockAnalyticsEnabled(BOOL enabled);
FOUNDATION_EXPORT void MatterSetDebugLoggingEnabled(BOOL enabled);
FOUNDATION_EXPORT void MatterSetClearCacheOnStartupEnabled(BOOL enabled);
