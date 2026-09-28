#import "MatterPreferences.h"
#import <dispatch/dispatch.h>

static NSString *const MatterBlockSponsoredPostsKey = @"com.panaikran.matter.blockSponsoredPosts";
static NSString *const MatterBlockAdTelemetryKey = @"com.panaikran.matter.blockAdTelemetry";
static NSString *const MatterBlockAnalyticsKey = @"com.panaikran.matter.blockAnalytics";
static NSString *const MatterDebugLoggingKey = @"com.panaikran.matter.debugLogging";
static NSString *const MatterClearCacheOnStartupKey = @"com.panaikran.matter.clearCacheOnStartup";
static NSString *const MatterPreferenceMigrationKey = @"com.panaikran.matter.legacyPreferencesMigrated";

static void MatterMigrateLegacyPreferences(NSUserDefaults *defaults) {
	if ([defaults boolForKey:MatterPreferenceMigrationKey]) {
		return;
	}

	NSArray<NSArray<NSString *> *> *mappings = @[
		@[ MatterBlockSponsoredPostsKey, @"com.example.matter.blockSponsoredPosts" ],
		@[ MatterBlockAdTelemetryKey, @"com.example.matter.blockAdTelemetry" ],
		@[ MatterBlockAnalyticsKey, @"com.example.matter.blockAnalytics" ],
		@[ MatterDebugLoggingKey, @"com.example.matter.debugLogging" ],
		@[ MatterClearCacheOnStartupKey, @"com.example.matter.clearCacheOnStartup" ]
	];
	for (NSArray<NSString *> *mapping in mappings) {
		NSString *currentKey = mapping[0];
		NSString *legacyKey = mapping[1];
		id currentValue = [defaults objectForKey:currentKey];
		id legacyValue = [defaults objectForKey:legacyKey];
		if (!currentValue && legacyValue) {
			[defaults setObject:legacyValue forKey:currentKey];
		}
	}
	[defaults setBool:YES forKey:MatterPreferenceMigrationKey];
}

static NSUserDefaults *MatterDefaults(void) {
	static NSUserDefaults *defaults;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		defaults = [NSUserDefaults standardUserDefaults];
		MatterMigrateLegacyPreferences(defaults);
		[defaults registerDefaults:@{
			MatterBlockSponsoredPostsKey: @YES,
			MatterBlockAdTelemetryKey: @NO,
			MatterBlockAnalyticsKey: @NO,
			MatterDebugLoggingKey: @NO,
			MatterClearCacheOnStartupKey: @NO
		}];
	});
	return defaults;
}

static BOOL MatterReadPreference(NSString *key) {
	return [MatterDefaults() boolForKey:key];
}

static void MatterWritePreference(NSString *key, BOOL enabled) {
	[MatterDefaults() setBool:enabled forKey:key];
}

BOOL MatterBlockSponsoredPostsEnabled(void) {
	return MatterReadPreference(MatterBlockSponsoredPostsKey);
}

BOOL MatterBlockAdTelemetryEnabled(void) {
	return MatterReadPreference(MatterBlockAdTelemetryKey);
}

BOOL MatterBlockAnalyticsEnabled(void) {
	return MatterReadPreference(MatterBlockAnalyticsKey);
}

BOOL MatterDebugLoggingEnabled(void) {
	return MatterReadPreference(MatterDebugLoggingKey);
}

BOOL MatterClearCacheOnStartupEnabled(void) {
	return MatterReadPreference(MatterClearCacheOnStartupKey);
}

void MatterSetBlockSponsoredPostsEnabled(BOOL enabled) {
	MatterWritePreference(MatterBlockSponsoredPostsKey, enabled);
}

void MatterSetBlockAdTelemetryEnabled(BOOL enabled) {
	MatterWritePreference(MatterBlockAdTelemetryKey, enabled);
}

void MatterSetBlockAnalyticsEnabled(BOOL enabled) {
	MatterWritePreference(MatterBlockAnalyticsKey, enabled);
}

void MatterSetDebugLoggingEnabled(BOOL enabled) {
	MatterWritePreference(MatterDebugLoggingKey, enabled);
}

void MatterSetClearCacheOnStartupEnabled(BOOL enabled) {
	MatterWritePreference(MatterClearCacheOnStartupKey, enabled);
}
