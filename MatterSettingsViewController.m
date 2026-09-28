#import "MatterSettingsViewController.h"
#import "MatterCacheManager.h"
#import "MatterPreferences.h"
#import <limits.h>

typedef NS_ENUM(NSInteger, MatterSettingsSection) {
	MatterSettingsSectionContent,
	MatterSettingsSectionPrivacy,
	MatterSettingsSectionCache,
	MatterSettingsSectionAdvanced,
	MatterSettingsSectionAbout,
	MatterSettingsSectionCount
};

typedef NS_ENUM(NSInteger, MatterSettingsSwitchTag) {
	MatterSettingsSwitchBlockSponsoredPosts = 1,
	MatterSettingsSwitchBlockAdTelemetry,
	MatterSettingsSwitchBlockAnalytics,
	MatterSettingsSwitchDebugLogging,
	MatterSettingsSwitchClearCacheOnStartup
};

static const uint64_t MatterCacheEffectivelyClearedThreshold = 5ull * 1024ull * 1024ull;

static BOOL MatterCacheClearHasFileWarning(MatterCacheClearResult result) {
	MatterCacheErrorSummary errors = result.errors;
	return result.bytesAfter > MatterCacheEffectivelyClearedThreshold ||
		errors.permission > 0 || errors.io > 0 || errors.other > 0 ||
		errors.invalidPath > 0 || errors.cancelled > 0;
}

@interface MatterSettingsViewController ()
@property (nonatomic, copy) NSString *cacheSizeText;
@property (nonatomic) uint64_t cacheSizeBytes;
@property (nonatomic) BOOL cacheSizeAvailable;
@property (nonatomic) BOOL cacheSizeCalculationInProgress;
@property (nonatomic) BOOL cacheClearInProgress;
@end

@implementation MatterSettingsViewController

- (instancetype)init {
	self = [super initWithStyle:UITableViewStyleInsetGrouped];
	if (self) {
		self.title = @"Matter for Threads";
	}
	return self;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
	return MatterSettingsSectionCount;
}

- (void)viewDidAppear:(BOOL)animated {
	[super viewDidAppear:animated];
	self.cacheClearInProgress = [MatterCacheManager isClearInProgress];
	[self refreshCacheSize];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
		switch (section) {
		case MatterSettingsSectionContent: return 1;
		case MatterSettingsSectionPrivacy: return 2;
		case MatterSettingsSectionCache: return 3;
		case MatterSettingsSectionAdvanced: return 1;
		case MatterSettingsSectionAbout: return 2;
		default: return 0;
	}
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
	switch (section) {
		case MatterSettingsSectionContent: return @"CONTENT";
		case MatterSettingsSectionPrivacy: return @"PRIVACY";
		case MatterSettingsSectionCache: return @"CACHE";
		case MatterSettingsSectionAdvanced: return @"ADVANCED";
		case MatterSettingsSectionAbout: return @"ABOUT";
		default: return nil;
	}
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
	cell.selectionStyle = UITableViewCellSelectionStyleNone;

	if (indexPath.section == MatterSettingsSectionContent) {
		cell.textLabel.text = @"Block Sponsored Posts";
		[self configureSwitchInCell:cell tag:MatterSettingsSwitchBlockSponsoredPosts
						 on:MatterBlockSponsoredPostsEnabled()];
		return cell;
	}
	if (indexPath.section == MatterSettingsSectionPrivacy) {
		if (indexPath.row == 0) {
			cell.textLabel.text = @"Block Ad Telemetry";
			[self configureSwitchInCell:cell tag:MatterSettingsSwitchBlockAdTelemetry
							 on:MatterBlockAdTelemetryEnabled()];
		} else {
			cell.textLabel.text = @"Block Analytics";
			[self configureSwitchInCell:cell tag:MatterSettingsSwitchBlockAnalytics
							 on:MatterBlockAnalyticsEnabled()];
		}
		return cell;
	}
	if (indexPath.section == MatterSettingsSectionCache) {
		if (indexPath.row == 0) {
			cell.textLabel.text = @"Cache Size";
			cell.detailTextLabel.text = self.cacheSizeText ?: @"Calculating…";
		} else if (indexPath.row == 1) {
			cell.textLabel.text = @"Clear Cache on Startup";
			[self configureSwitchInCell:cell tag:MatterSettingsSwitchClearCacheOnStartup
								 on:MatterClearCacheOnStartupEnabled()];
		} else {
			cell.textLabel.text = @"Clear Cache";
			cell.textLabel.textColor = UIColor.systemBlueColor;
			cell.textLabel.textAlignment = NSTextAlignmentLeft;
			cell.selectionStyle = UITableViewCellSelectionStyleDefault;
			cell.accessoryType = UITableViewCellAccessoryNone;
			BOOL clearing = self.cacheClearInProgress || [MatterCacheManager isClearInProgress];
			cell.userInteractionEnabled = !clearing;
			if (clearing) cell.detailTextLabel.text = @"Clearing…";
		}
		return cell;
	}
	if (indexPath.section == MatterSettingsSectionAdvanced) {
		cell.textLabel.text = @"Debug Logging";
		[self configureSwitchInCell:cell tag:MatterSettingsSwitchDebugLogging on:MatterDebugLoggingEnabled()];
		return cell;
	}

	if (indexPath.row == 0) {
		cell.textLabel.text = @"Matter version";
		cell.detailTextLabel.text = [MATTER_VERSION stringByReplacingOccurrencesOfString:@"~rc"
			withString:@" RC" options:NSCaseInsensitiveSearch range:NSMakeRange(0, MATTER_VERSION.length)];
	} else {
		id versionValue = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
		NSString *threadsVersion = [versionValue isKindOfClass:NSString.class] ? versionValue : nil;
		cell.textLabel.text = @"Threads version";
		cell.detailTextLabel.text = threadsVersion.length > 0 ? threadsVersion : @"—";
	}
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	if (indexPath.section == MatterSettingsSectionCache && indexPath.row == 2 &&
		!self.cacheClearInProgress && ![MatterCacheManager isClearInProgress]) {
		[self confirmCacheClear];
	}
}

- (NSString *)formattedCacheSize:(uint64_t)bytes {
	long long count = bytes > (uint64_t)LLONG_MAX ? LLONG_MAX : (long long)bytes;
	return [NSByteCountFormatter stringFromByteCount:count countStyle:NSByteCountFormatterCountStyleFile];
}

- (void)refreshCacheSize {
	if (self.cacheSizeCalculationInProgress) return;
	self.cacheSizeCalculationInProgress = YES;
	self.cacheSizeText = @"Calculating…";
	[self.tableView reloadData];
	[MatterCacheManager asynchronouslyCalculateCacheSizeWithCompletion:^(MatterCacheSizeResult result) {
		self.cacheSizeCalculationInProgress = NO;
		self.cacheSizeAvailable = result.available;
		self.cacheSizeBytes = result.bytes;
		self.cacheSizeText = result.available ? [self formattedCacheSize:result.bytes] : @"—";
		self.cacheClearInProgress = [MatterCacheManager isClearInProgress];
		[self.tableView reloadData];
		if (self.cacheClearInProgress) [self refreshCacheSize];
	}];
}

- (void)confirmCacheClear {
	NSString *message = self.cacheSizeAvailable
		? [NSString stringWithFormat:@"Clear approximately %@ of cached Threads data? Your account, settings, and other app data will not be removed.", [self formattedCacheSize:self.cacheSizeBytes]]
		: @"Clear cached Threads data? Your account, settings, and other app data will not be removed.";
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Clear Cache?"
		message:message preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
	[alert addAction:[UIAlertAction actionWithTitle:@"Clear Cache" style:UIAlertActionStyleDestructive
		handler:^(__unused UIAlertAction *action) { [self clearCache]; }]];
	[self presentViewController:alert animated:YES completion:nil];
}

- (void)clearCache {
	self.cacheClearInProgress = YES;
	[self.tableView reloadData];
	BOOL started = [MatterCacheManager asynchronouslyClearCacheWithCompletion:^(MatterCacheClearResult result) {
		self.cacheClearInProgress = NO;
		[self refreshCacheSize];
		NSString *freed = [self formattedCacheSize:result.bytesFreed];
		NSString *message = [NSString stringWithFormat:@"Freed approximately %@.", freed];
		if (result.rootsSkippedUnsafe == 1) {
			message = [message stringByAppendingString:@" One cache location could not be safely validated and was left unchanged."];
		} else if (result.rootsSkippedUnsafe > 1) {
			message = [message stringByAppendingString:@" Some cache locations could not be safely validated and were left unchanged."];
		}
		if (MatterCacheClearHasFileWarning(result)) {
			message = [message stringByAppendingString:@" Some cached files could not be removed."];
		}
		if (self.view.window) {
			UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Cache Cleared"
				message:message preferredStyle:UIAlertControllerStyleAlert];
			[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
			[self presentViewController:alert animated:YES completion:nil];
		}
	}];
	if (!started) {
		self.cacheClearInProgress = [MatterCacheManager isClearInProgress];
		[self refreshCacheSize];
	}
}

- (void)configureSwitchInCell:(UITableViewCell *)cell tag:(MatterSettingsSwitchTag)tag on:(BOOL)on {
	UISwitch *control = [[UISwitch alloc] init];
	control.tag = tag;
	control.on = on;
	[control addTarget:self action:@selector(matterSwitchChanged:) forControlEvents:UIControlEventValueChanged];
	cell.accessoryView = control;
}

- (void)matterSwitchChanged:(UISwitch *)sender {
	switch (sender.tag) {
		case MatterSettingsSwitchBlockSponsoredPosts:
			MatterSetBlockSponsoredPostsEnabled(sender.isOn);
			break;
		case MatterSettingsSwitchBlockAdTelemetry:
			MatterSetBlockAdTelemetryEnabled(sender.isOn);
			break;
		case MatterSettingsSwitchBlockAnalytics:
			MatterSetBlockAnalyticsEnabled(sender.isOn);
			break;
		case MatterSettingsSwitchClearCacheOnStartup:
			MatterSetClearCacheOnStartupEnabled(sender.isOn);
			break;
		case MatterSettingsSwitchDebugLogging:
			MatterSetDebugLoggingEnabled(sender.isOn);
			break;
	}
}

@end
