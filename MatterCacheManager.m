#import "MatterCacheManager.h"

#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#import <errno.h>
#import <os/log.h>
#import <string.h>

#import "MatterPreferences.h"

#define MATTER_CACHE_LOG(...) do { if (MatterDebugLoggingEnabled()) os_log(OS_LOG_DEFAULT, "[Matter:Cache] " __VA_ARGS__); } while (0)

static BOOL MatterCacheClearing;
static dispatch_once_t MatterStartupClearOnce;

typedef NS_ENUM(NSUInteger, MatterCacheErrorCategory) {
	MatterCacheErrorCategoryNotFound,
	MatterCacheErrorCategoryPermission,
	MatterCacheErrorCategoryBusy,
	MatterCacheErrorCategoryCancelled,
	MatterCacheErrorCategoryInvalidPath,
	MatterCacheErrorCategoryIO,
	MatterCacheErrorCategoryOther
};

typedef NS_ENUM(NSUInteger, MatterCacheRootAuthorization) {
	MatterCacheRootAuthorizationInsideTrustedContainer,
	MatterCacheRootAuthorizationValidatedTmpAlias
};

@interface MatterCacheRoot : NSObject
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, strong) NSURL *containerURL;
@property (nonatomic, copy) NSString *label;
@property (nonatomic) MatterCacheRootAuthorization authorization;
@property (nonatomic) BOOL unsafe;
@property (nonatomic) BOOL unavailable;
@end

@implementation MatterCacheRoot
@end

@interface MatterCacheRootResolution : NSObject
@property (nonatomic, strong) NSMutableArray<MatterCacheRoot *> *roots;
@property (nonatomic) NSUInteger rootsAccepted;
@property (nonatomic) NSUInteger rootsSkippedUnsafe;
@end

@implementation MatterCacheRootResolution
@end

static dispatch_queue_t MatterCacheQueue(void) {
	static dispatch_queue_t queue;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		queue = dispatch_queue_create("com.panaikran.matter.cache", DISPATCH_QUEUE_SERIAL);
	});
	return queue;
}

static const char *MatterCacheCategoryName(MatterCacheErrorCategory category) {
	switch (category) {
		case MatterCacheErrorCategoryNotFound: return "notFound";
		case MatterCacheErrorCategoryPermission: return "permission";
		case MatterCacheErrorCategoryBusy: return "busy";
		case MatterCacheErrorCategoryCancelled: return "cancelled";
		case MatterCacheErrorCategoryInvalidPath: return "invalidPath";
		case MatterCacheErrorCategoryIO: return "io";
		case MatterCacheErrorCategoryOther: return "other";
	}
	return "other";
}

static MatterCacheErrorCategory MatterCacheClassifyError(NSError *error) {
	for (NSUInteger depth = 0; error && depth < 2; depth++) {
		if ([error.domain isEqualToString:NSPOSIXErrorDomain]) {
		switch ((int)error.code) {
				case ENOENT: return MatterCacheErrorCategoryNotFound;
				case EACCES:
				case EPERM: return MatterCacheErrorCategoryPermission;
				case EBUSY: return MatterCacheErrorCategoryBusy;
				case ECANCELED: return MatterCacheErrorCategoryCancelled;
				case EINVAL: return MatterCacheErrorCategoryInvalidPath;
				case EIO: return MatterCacheErrorCategoryIO;
			}
		} else if ([error.domain isEqualToString:NSCocoaErrorDomain]) {
			switch (error.code) {
				case NSFileNoSuchFileError:
				case NSFileReadNoSuchFileError: return MatterCacheErrorCategoryNotFound;
				case NSFileReadNoPermissionError:
				case NSFileWriteNoPermissionError: return MatterCacheErrorCategoryPermission;
				case NSFileLockingError: return MatterCacheErrorCategoryBusy;
				case NSUserCancelledError: return MatterCacheErrorCategoryCancelled;
				case NSFileReadInvalidFileNameError:
				case NSFileWriteInvalidFileNameError: return MatterCacheErrorCategoryInvalidPath;
			}
		}

		id underlying = error.userInfo[NSUnderlyingErrorKey];
		error = [underlying isKindOfClass:NSError.class] ? underlying : nil;
	}
	return MatterCacheErrorCategoryOther;
}

static void MatterCacheIncrementCategory(MatterCacheErrorSummary *summary, MatterCacheErrorCategory category) {
	if (!summary) return;
	summary->total++;
	switch (category) {
		case MatterCacheErrorCategoryNotFound: summary->notFound++; break;
		case MatterCacheErrorCategoryPermission: summary->permission++; break;
		case MatterCacheErrorCategoryBusy: summary->busy++; break;
		case MatterCacheErrorCategoryCancelled: summary->cancelled++; break;
		case MatterCacheErrorCategoryInvalidPath: summary->invalidPath++; break;
		case MatterCacheErrorCategoryIO: summary->io++; break;
		case MatterCacheErrorCategoryOther: summary->other++; break;
	}
}

static void MatterCacheRecordError(MatterCacheErrorSummary *summary, NSError *error,
								   NSString *stage, NSString *root, MatterCacheErrorCategory noErrorCategory) {
	MatterCacheErrorCategory category = error ? MatterCacheClassifyError(error) : noErrorCategory;
	MatterCacheIncrementCategory(summary, category);
	if (!MatterDebugLoggingEnabled()) return;

	NSString *domain = error.domain ?: @"none";
	NSError *underlying = [error.userInfo[NSUnderlyingErrorKey] isKindOfClass:NSError.class]
		? error.userInfo[NSUnderlyingErrorKey] : nil;
	if (underlying) {
		os_log(OS_LOG_DEFAULT,
			"[Matter:Cache] error stage=%{public}s root=%{public}s domain=%{public}s code=%{public}ld category=%{public}s underlyingDomain=%{public}s underlyingCode=%{public}ld",
			stage.UTF8String, root.UTF8String, domain.UTF8String, (long)error.code,
			MatterCacheCategoryName(category), underlying.domain.UTF8String, (long)underlying.code);
	} else {
		os_log(OS_LOG_DEFAULT,
			"[Matter:Cache] error stage=%{public}s root=%{public}s domain=%{public}s code=%{public}ld category=%{public}s",
			stage.UTF8String, root.UTF8String, domain.UTF8String, (long)error.code,
			MatterCacheCategoryName(category));
	}
}

static void MatterCacheRecordException(MatterCacheErrorSummary *summary, NSException *exception,
										   NSString *stage, NSString *root) {
	NSString *domain = exception.name.length > 0 ? exception.name : @"NSException";
	NSError *error = [NSError errorWithDomain:domain code:0 userInfo:nil];
	MatterCacheRecordError(summary, error, stage, root, MatterCacheErrorCategoryOther);
}

static void MatterCacheMergeErrors(MatterCacheErrorSummary *target, MatterCacheErrorSummary source) {
	target->total += source.total;
	target->notFound += source.notFound;
	target->permission += source.permission;
	target->busy += source.busy;
	target->cancelled += source.cancelled;
	target->invalidPath += source.invalidPath;
	target->io += source.io;
	target->other += source.other;
}

static NSString *MatterCacheErrorCounts(MatterCacheErrorSummary summary) {
	return [NSString stringWithFormat:
		@"errors=%lu notFound=%lu permission=%lu busy=%lu cancelled=%lu invalidPath=%lu io=%lu other=%lu",
		(unsigned long)summary.total, (unsigned long)summary.notFound, (unsigned long)summary.permission,
		(unsigned long)summary.busy, (unsigned long)summary.cancelled, (unsigned long)summary.invalidPath,
		(unsigned long)summary.io, (unsigned long)summary.other];
}

static BOOL MatterPathIsWithin(NSString *path, NSString *root) {
	if (!path.length || !root.length) return NO;
	NSArray<NSString *> *pathComponents = path.stringByStandardizingPath.pathComponents;
	NSArray<NSString *> *rootComponents = root.stringByStandardizingPath.pathComponents;
	if (pathComponents.count < rootComponents.count) return NO;
	for (NSUInteger index = 0; index < rootComponents.count; index++) {
		if (![pathComponents[index] isEqualToString:rootComponents[index]]) return NO;
	}
	return YES;
}

static BOOL MatterURLsHaveSameCanonicalPath(NSURL *left, NSURL *right) {
	if (!left.isFileURL || !right.isFileURL) return NO;
	NSURL *leftStandard = [left URLByStandardizingPath];
	NSURL *rightStandard = [right URLByStandardizingPath];
	return [leftStandard.path isEqualToString:rightStandard.path];
}

typedef struct {
	BOOL urlCreated;
	BOOL rootAttributesRead;
	BOOL rootIsSymlink;
	BOOL ancestorSymlinkCheckCompleted;
	BOOL ancestorSymlinkDetected;
	BOOL canonicalizationAttempted;
	BOOL canonicalizationSucceeded;
	BOOL canonicalizationChanged;
	BOOL resolvedTargetExists;
	BOOL genericSymlinkGuardTriggered;
	const char *failureReason;
} MatterTmpPathDiagnostic;

typedef struct {
	MatterTmpPathDiagnostic actual;
	MatterTmpPathDiagnostic expected;
	BOOL canonicalEqualityAttempted;
	BOOL canonicalMatch;
	BOOL identityCheckAttempted;
	BOOL identityCheckSucceeded;
	BOOL filesystemIdentityMatch;
	BOOL specialValidationAttempted;
} MatterTmpValidationDiagnostic;

static BOOL MatterHasSymlinkedAncestor(NSURL *url, BOOL *checkCompleted) {
	if (checkCompleted) *checkCompleted = NO;
	if (!url.isFileURL || !url.path.isAbsolutePath) return NO;

	NSArray<NSString *> *components = url.path.pathComponents;
	if (components.count < 2) {
		if (checkCompleted) *checkCompleted = YES;
		return NO;
	}

	NSString *prefix = components.firstObject;
	BOOL completed = YES;
	BOOL found = NO;
	for (NSUInteger index = 1; index + 1 < components.count; index++) {
		prefix = [prefix stringByAppendingPathComponent:components[index]];
		NSURL *componentURL = [NSURL fileURLWithPath:prefix isDirectory:YES];
		NSNumber *isSymbolicLink = nil;
		BOOL symbolicLinkRead = [componentURL getResourceValue:&isSymbolicLink forKey:NSURLIsSymbolicLinkKey error:nil];
		NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:prefix error:nil];
		if (!attributes && !symbolicLinkRead) {
			completed = NO;
			continue;
		}
		if ([attributes[NSFileType] isEqualToString:NSFileTypeSymbolicLink] ||
			(symbolicLinkRead && isSymbolicLink.boolValue)) found = YES;
	}
	if (checkCompleted) *checkCompleted = completed;
	return found;
}

static NSURL *MatterCanonicalDirectoryURL(NSURL *url, BOOL allowRootSymlink, BOOL *wasRootSymlink,
									  NSString **reason, MatterTmpPathDiagnostic *diagnostic) {
	if (wasRootSymlink) *wasRootSymlink = NO;
	if (diagnostic) {
		diagnostic->urlCreated = url != nil;
		diagnostic->failureReason = "other";
	}
	if (!url.isFileURL || !url.path.isAbsolutePath) {
		if (reason) *reason = @"canonicalizationFailed";
		if (diagnostic) diagnostic->failureReason = "canonicalizationFailure";
		return nil;
	}

	NSURL *standardURL = [url URLByStandardizingPath];
	NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:standardURL.path error:nil];
	if (!attributes) {
		if (reason) *reason = @"missingSystemRoot";
		if (diagnostic) diagnostic->failureReason = "missingRoot";
		return nil;
	}
	if (diagnostic) diagnostic->rootAttributesRead = YES;
	NSNumber *isSymbolicLink = nil;
	if (![standardURL getResourceValue:&isSymbolicLink forKey:NSURLIsSymbolicLinkKey error:nil]) {
		if (reason) *reason = @"canonicalizationFailed";
		if (diagnostic) diagnostic->failureReason = "rootSymlinkMetadataUnavailable";
		return nil;
	}
	BOOL rootSymlink = [attributes[NSFileType] isEqualToString:NSFileTypeSymbolicLink] || isSymbolicLink.boolValue;
	if (diagnostic) diagnostic->rootIsSymlink = rootSymlink;
	if (wasRootSymlink) *wasRootSymlink = rootSymlink;
	if (rootSymlink && !allowRootSymlink) {
		if (reason) *reason = @"unsafeSymlink";
		if (diagnostic) {
			diagnostic->genericSymlinkGuardTriggered = YES;
			diagnostic->failureReason = "rootSymlink";
		}
		return nil;
	}
	if (!rootSymlink && ![attributes[NSFileType] isEqualToString:NSFileTypeDirectory]) {
		if (reason) *reason = @"invalidCachesStructure";
		if (diagnostic) diagnostic->failureReason = "invalidRootType";
		return nil;
	}

	if (diagnostic) diagnostic->canonicalizationAttempted = YES;
	NSURL *resolvedURL = [[standardURL URLByResolvingSymlinksInPath] URLByStandardizingPath];
	NSDictionary *resolvedAttributes = [NSFileManager.defaultManager attributesOfItemAtPath:resolvedURL.path error:nil];
	if (diagnostic) {
		diagnostic->canonicalizationChanged = ![standardURL.path isEqualToString:resolvedURL.path];
		diagnostic->resolvedTargetExists = [resolvedAttributes[NSFileType] isEqualToString:NSFileTypeDirectory];
	}
	if (!resolvedURL.isFileURL || !resolvedURL.path.isAbsolutePath || !resolvedAttributes ||
		![resolvedAttributes[NSFileType] isEqualToString:NSFileTypeDirectory]) {
		if (reason) *reason = @"canonicalizationFailed";
		if (diagnostic) diagnostic->failureReason = "canonicalizationFailure";
		return nil;
	}
	if (diagnostic) diagnostic->canonicalizationSucceeded = YES;
	NSNumber *resolvedIsSymbolicLink = nil;
	if (![resolvedURL getResourceValue:&resolvedIsSymbolicLink forKey:NSURLIsSymbolicLinkKey error:nil] ||
		resolvedIsSymbolicLink.boolValue) {
		if (reason) *reason = @"unsafeSymlink";
		if (diagnostic) {
			diagnostic->genericSymlinkGuardTriggered = YES;
			diagnostic->failureReason = resolvedIsSymbolicLink.boolValue
				? "resolvedRootStillSymlink" : "resolvedSymlinkMetadataUnavailable";
		}
		return nil;
	}
	return resolvedURL;
}

static const char *MatterTmpDiagnosticReason(MatterTmpValidationDiagnostic diagnostic, BOOL accepted) {
	if (diagnostic.expected.genericSymlinkGuardTriggered) return "expectedAliasResolutionFailed";
	if (diagnostic.actual.genericSymlinkGuardTriggered) {
		return "genericGuardPreemptedTmpValidation";
	}
	if (accepted && diagnostic.expected.rootIsSymlink) return "validatedExpectedRootSymlink";
	if (accepted) return diagnostic.filesystemIdentityMatch ? "filesystemIdentityMatch" : "canonicalMatch";
	if (!diagnostic.actual.canonicalizationSucceeded || !diagnostic.expected.canonicalizationSucceeded) {
		if (!diagnostic.expected.canonicalizationSucceeded && diagnostic.expected.failureReason &&
			strcmp(diagnostic.expected.failureReason, "missingRoot") == 0) return "expectedAliasMissing";
		if (!diagnostic.expected.canonicalizationSucceeded) return "expectedAliasResolutionFailed";
		if (!diagnostic.actual.canonicalizationSucceeded && diagnostic.actual.failureReason &&
			strcmp(diagnostic.actual.failureReason, "missingRoot") == 0) return "missingTmpRoot";
		return "canonicalizationFailure";
	}
	if (diagnostic.identityCheckAttempted && diagnostic.identityCheckSucceeded) return "expectedAliasIdentityMismatch";
	if (diagnostic.canonicalEqualityAttempted) return "expectedAliasTargetMismatch";
	if (diagnostic.actual.ancestorSymlinkDetected || diagnostic.expected.ancestorSymlinkDetected) return "ancestorSymlink";
	if (diagnostic.actual.rootIsSymlink) return "rootSymlink";
	return "other";
}

static void MatterCacheLogTmpDiagnostic(MatterTmpValidationDiagnostic diagnostic, BOOL accepted) {
	if (!MatterDebugLoggingEnabled()) return;
	const MatterTmpPathDiagnostic actual = diagnostic.actual;
	const MatterTmpPathDiagnostic expected = diagnostic.expected;
	const char *reason = MatterTmpDiagnosticReason(diagnostic, accepted);
	os_log(OS_LOG_DEFAULT,
		"[Matter:Cache] tmp diagnostic actualURLCreated=%{public}d rootAttributesRead=%{public}d rootIsSymlink=%{public}d ancestorSymlinkCheckCompleted=%{public}d ancestorSymlinkDetected=%{public}d expectedURLCreated=%{public}d expectedRootAttributesRead=%{public}d expectedRootSymlink=%{public}d expectedAncestorSymlinkCheckCompleted=%{public}d expectedAncestorSymlinkDetected=%{public}d",
		actual.urlCreated, actual.rootAttributesRead, actual.rootIsSymlink,
		actual.ancestorSymlinkCheckCompleted, actual.ancestorSymlinkDetected,
		expected.urlCreated, expected.rootAttributesRead, expected.rootIsSymlink,
		expected.ancestorSymlinkCheckCompleted, expected.ancestorSymlinkDetected);
	os_log(OS_LOG_DEFAULT,
		"[Matter:Cache] tmp diagnostic canonicalizationAttempted=%{public}d canonicalizationSucceeded=%{public}d canonicalizationChanged=%{public}d resolvedTargetExists=%{public}d expectedCanonicalizationAttempted=%{public}d expectedCanonicalizationSucceeded=%{public}d expectedCanonicalizationChanged=%{public}d expectedTargetExists=%{public}d canonicalEqualityAttempted=%{public}d canonicalMatch=%{public}d identityCheckAttempted=%{public}d identityCheckSucceeded=%{public}d filesystemIdentityMatch=%{public}d specialValidationAttempted=%{public}d genericSymlinkGuardTriggered=%{public}d diagnosticReason=%{public}s",
		actual.canonicalizationAttempted, actual.canonicalizationSucceeded,
		actual.canonicalizationChanged, actual.resolvedTargetExists,
		expected.canonicalizationAttempted, expected.canonicalizationSucceeded,
		expected.canonicalizationChanged, expected.resolvedTargetExists,
		diagnostic.canonicalEqualityAttempted, diagnostic.canonicalMatch,
		diagnostic.identityCheckAttempted, diagnostic.identityCheckSucceeded,
		diagnostic.filesystemIdentityMatch, diagnostic.specialValidationAttempted,
		(actual.genericSymlinkGuardTriggered || expected.genericSymlinkGuardTriggered), reason);
}

static BOOL MatterDirectoryResourceIdentifiersMatch(NSURL *left, NSURL *right, BOOL *available) {
	id leftIdentifier = nil;
	id rightIdentifier = nil;
	BOOL leftAvailable = [left getResourceValue:&leftIdentifier forKey:NSURLFileResourceIdentifierKey error:nil] && leftIdentifier != nil;
	BOOL rightAvailable = [right getResourceValue:&rightIdentifier forKey:NSURLFileResourceIdentifierKey error:nil] && rightIdentifier != nil;
	if (available) *available = leftAvailable && rightAvailable;
	return leftAvailable && rightAvailable && [leftIdentifier isEqual:rightIdentifier];
}

static void MatterCacheLogRootValidation(NSString *label, BOOL accepted, NSString *reason) {
	if (!MatterDebugLoggingEnabled()) return;
	os_log(OS_LOG_DEFAULT,
		"[Matter:Cache] root validation root=%{public}s accepted=%{public}d reason=%{public}s",
		label.UTF8String, accepted ? 1 : 0, reason.UTF8String);
}

static void MatterCacheAcceptRoot(MatterCacheRootResolution *resolution, NSURL *url, NSURL *containerURL,
								  NSString *label, NSString *reason,
								  MatterCacheRootAuthorization authorization) {
	MatterCacheRoot *root = [MatterCacheRoot new];
	root.url = url;
	root.containerURL = containerURL;
	root.label = label;
	root.authorization = authorization;
	[resolution.roots addObject:root];
	resolution.rootsAccepted++;
	MatterCacheLogRootValidation(label, YES, reason);
}

static void MatterCacheSkipRoot(MatterCacheRootResolution *resolution, NSString *label, NSString *reason) {
	resolution.rootsSkippedUnsafe++;
	MatterCacheLogRootValidation(label, NO, reason ?: @"other");
}

static MatterCacheRootResolution *MatterApprovedCacheRoots(void) {
	NSFileManager *fileManager = NSFileManager.defaultManager;
	MatterCacheRootResolution *resolution = [MatterCacheRootResolution new];
	resolution.roots = [NSMutableArray arrayWithCapacity:2];

	NSURL *systemCachesURL = [fileManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
	NSString *cacheReason = nil;
	NSURL *cachesURL = MatterCanonicalDirectoryURL(systemCachesURL, NO, NULL, &cacheReason, NULL);
	NSURL *containerURL = nil;
	if (cachesURL) {
		NSArray<NSString *> *components = cachesURL.path.pathComponents;
		if (components.count >= 4 && [cachesURL.lastPathComponent isEqualToString:@"Caches"] &&
			[[cachesURL URLByDeletingLastPathComponent].lastPathComponent isEqualToString:@"Library"]) {
			NSURL *libraryURL = [cachesURL URLByDeletingLastPathComponent];
			NSURL *candidateContainerURL = [libraryURL URLByDeletingLastPathComponent];
			NSString *structureReason = nil;
			NSURL *canonicalLibraryURL = MatterCanonicalDirectoryURL(libraryURL, NO, NULL, &structureReason, NULL);
			NSURL *canonicalContainerURL = MatterCanonicalDirectoryURL(candidateContainerURL, NO, NULL, &structureReason, NULL);
			if (canonicalLibraryURL && canonicalContainerURL &&
				MatterURLsHaveSameCanonicalPath(libraryURL, canonicalLibraryURL) &&
				MatterURLsHaveSameCanonicalPath(candidateContainerURL, canonicalContainerURL) &&
				canonicalContainerURL.path.length > 1) {
				containerURL = canonicalContainerURL;
			} else {
				cacheReason = structureReason ?: @"invalidCachesStructure";
			}
		} else {
			cacheReason = @"invalidCachesStructure";
		}
	}

	if (containerURL) {
		MatterCacheAcceptRoot(resolution, cachesURL, containerURL, @"caches", @"systemCaches",
			MatterCacheRootAuthorizationInsideTrustedContainer);
	} else {
		MatterCacheSkipRoot(resolution, @"caches", cacheReason ?: @"missingSystemRoot");
		MatterCacheSkipRoot(resolution, @"tmp", @"missingSystemRoot");
		return resolution;
	}

	NSString *temporaryPath = NSTemporaryDirectory();
	NSURL *temporaryInputURL = temporaryPath.length ? [NSURL fileURLWithPath:temporaryPath isDirectory:YES] : nil;
	BOOL collectDiagnostics = MatterDebugLoggingEnabled();
	MatterTmpValidationDiagnostic diagnostic = { 0 };
	if (collectDiagnostics) {
		diagnostic.actual.ancestorSymlinkDetected = MatterHasSymlinkedAncestor(temporaryInputURL,
			&diagnostic.actual.ancestorSymlinkCheckCompleted);
	}
	NSString *temporaryReason = nil;
	BOOL temporaryRootIsSymlink = NO;
	NSURL *temporaryURL = MatterCanonicalDirectoryURL(temporaryInputURL, YES, &temporaryRootIsSymlink,
		&temporaryReason, collectDiagnostics ? &diagnostic.actual : NULL);
	NSURL *expectedTemporaryInputURL = [containerURL URLByAppendingPathComponent:@"tmp" isDirectory:YES];
	if (collectDiagnostics) {
		diagnostic.expected.ancestorSymlinkDetected = MatterHasSymlinkedAncestor(expectedTemporaryInputURL,
			&diagnostic.expected.ancestorSymlinkCheckCompleted);
	}
	NSString *expectedReason = nil;
	BOOL expectedTemporaryRootIsSymlink = NO;
	NSURL *expectedTemporaryURL = MatterCanonicalDirectoryURL(expectedTemporaryInputURL, YES, &expectedTemporaryRootIsSymlink,
		&expectedReason, collectDiagnostics ? &diagnostic.expected : NULL);
	if (!temporaryURL || !expectedTemporaryURL) {
		NSString *rejectionReason = nil;
		if (!temporaryURL) {
			rejectionReason = temporaryRootIsSymlink ? @"symlinkTargetMismatch" : (temporaryReason ?: @"canonicalizationFailure");
		} else {
			rejectionReason = [expectedReason isEqualToString:@"missingSystemRoot"]
				? @"expectedAliasMissing" : @"expectedAliasResolutionFailed";
		}
		if (collectDiagnostics) MatterCacheLogTmpDiagnostic(diagnostic, NO);
		MatterCacheSkipRoot(resolution, @"tmp", rejectionReason);
		return resolution;
	}

	NSString *acceptedReason = nil;
	if (collectDiagnostics) {
		diagnostic.specialValidationAttempted = YES;
		diagnostic.canonicalEqualityAttempted = YES;
	}
	BOOL canonicalMatch = MatterURLsHaveSameCanonicalPath(temporaryURL, expectedTemporaryURL);
	if (collectDiagnostics) diagnostic.canonicalMatch = canonicalMatch;
	if (canonicalMatch) {
		acceptedReason = expectedTemporaryRootIsSymlink ? @"validatedExpectedRootSymlink" :
			(temporaryRootIsSymlink ? @"validatedRootSymlink" : @"acceptedCanonicalMatch");
	} else {
		BOOL identifiersAvailable = NO;
		if (collectDiagnostics) diagnostic.identityCheckAttempted = YES;
		BOOL identityMatch = MatterDirectoryResourceIdentifiersMatch(temporaryURL, expectedTemporaryURL, &identifiersAvailable);
		if (collectDiagnostics) {
			diagnostic.identityCheckSucceeded = identifiersAvailable;
			diagnostic.filesystemIdentityMatch = identityMatch;
		}
		if (identityMatch) {
			acceptedReason = expectedTemporaryRootIsSymlink ? @"validatedExpectedRootSymlink" :
				(temporaryRootIsSymlink ? @"validatedRootSymlink" : @"acceptedFilesystemIdentity");
		} else {
			if (collectDiagnostics) MatterCacheLogTmpDiagnostic(diagnostic, NO);
			MatterCacheSkipRoot(resolution, @"tmp", identifiersAvailable
				? @"expectedAliasIdentityMismatch" : @"expectedAliasTargetMismatch");
			return resolution;
		}
	}

	if (collectDiagnostics) MatterCacheLogTmpDiagnostic(diagnostic, YES);
	MatterCacheRootAuthorization authorization = MatterPathIsWithin(temporaryURL.path, containerURL.path)
		? MatterCacheRootAuthorizationInsideTrustedContainer
		: MatterCacheRootAuthorizationValidatedTmpAlias;
	MatterCacheAcceptRoot(resolution, temporaryURL, containerURL, @"tmp", acceptedReason, authorization);
	return resolution;
}

static void MatterCacheMarkRootUnsafe(MatterCacheRootResolution *resolution, MatterCacheRoot *root, NSString *reason) {
	if (root.unsafe) return;
	root.unsafe = YES;
	if (resolution.rootsAccepted > 0) resolution.rootsAccepted--;
	resolution.rootsSkippedUnsafe++;
	MatterCacheLogRootValidation(root.label, NO, reason);
}

static BOOL MatterExistingRootIsSafe(MatterCacheRoot *root, MatterCacheRootResolution *resolution,
									 MatterCacheErrorSummary *errors) {
	if (root.unsafe || root.unavailable) return NO;

	NSFileManager *fileManager = NSFileManager.defaultManager;
	NSError *statError = nil;
	NSDictionary *attributes = [fileManager attributesOfItemAtPath:root.url.path error:&statError];
	if (!attributes) {
		MatterCacheRecordError(errors, statError, @"stat", root.label, MatterCacheErrorCategoryOther);
		root.unavailable = YES;
		return NO;
	}
	if ([attributes[NSFileType] isEqualToString:NSFileTypeSymbolicLink]) {
		MatterCacheMarkRootUnsafe(resolution, root, @"unsafeSymlink");
		return NO;
	}
	if (![attributes[NSFileType] isEqualToString:NSFileTypeDirectory]) {
		MatterCacheMarkRootUnsafe(resolution, root, @"invalidCachesStructure");
		return NO;
	}

	NSNumber *isSymbolicLink = nil;
	NSError *resourceError = nil;
	if (![root.url getResourceValue:&isSymbolicLink forKey:NSURLIsSymbolicLinkKey error:&resourceError]) {
		MatterCacheRecordError(errors, resourceError, @"resourceValues", root.label, MatterCacheErrorCategoryOther);
		root.unavailable = YES;
		return NO;
	}
	if (isSymbolicLink.boolValue) {
		MatterCacheMarkRootUnsafe(resolution, root, @"unsafeSymlink");
		return NO;
	}

	NSURL *currentRootURL = [[root.url URLByResolvingSymlinksInPath] URLByStandardizingPath];
	NSURL *currentContainerURL = [[root.containerURL URLByResolvingSymlinksInPath] URLByStandardizingPath];
	BOOL isTmpAliasAuthorized = root.authorization == MatterCacheRootAuthorizationValidatedTmpAlias &&
		[root.label isEqualToString:@"tmp"];
	BOOL invalidTmpAliasAuthorization = root.authorization == MatterCacheRootAuthorizationValidatedTmpAlias && !isTmpAliasAuthorized;
	if (!MatterURLsHaveSameCanonicalPath(root.url, currentRootURL) ||
		!MatterURLsHaveSameCanonicalPath(root.containerURL, currentContainerURL) ||
		(invalidTmpAliasAuthorization || (!isTmpAliasAuthorized &&
			!MatterPathIsWithin(currentRootURL.path, currentContainerURL.path))) ||
		MatterURLsHaveSameCanonicalPath(currentRootURL, currentContainerURL)) {
		MatterCacheMarkRootUnsafe(resolution, root, @"outsideContainer");
		return NO;
	}
	return YES;
}

static NSArray<MatterCacheRoot *> *MatterNonOverlappingRoots(NSArray<MatterCacheRoot *> *roots) {
	NSArray<MatterCacheRoot *> *sorted = [roots sortedArrayUsingComparator:^NSComparisonResult(MatterCacheRoot *left, MatterCacheRoot *right) {
		return left.url.path.length < right.url.path.length ? NSOrderedAscending :
			(left.url.path.length > right.url.path.length ? NSOrderedDescending : NSOrderedSame);
	}];
	NSMutableArray<MatterCacheRoot *> *result = [NSMutableArray arrayWithCapacity:sorted.count];
	for (MatterCacheRoot *candidate in sorted) {
		BOOL covered = NO;
		for (MatterCacheRoot *root in result) {
			if (MatterPathIsWithin(candidate.url.path, root.url.path)) {
				covered = YES;
				break;
			}
		}
		if (!covered) [result addObject:candidate];
	}
	return result;
}

static BOOL MatterFileSize(NSURL *url, uint64_t *bytes, NSError **outError) {
	NSArray<NSURLResourceKey> *keys = @[
		NSURLTotalFileAllocatedSizeKey,
		NSURLFileAllocatedSizeKey,
		NSURLFileSizeKey
	];
	NSError *lastError = nil;
	for (NSURLResourceKey key in keys) {
		NSNumber *value = nil;
		NSError *resourceError = nil;
		if ([url getResourceValue:&value forKey:key error:&resourceError] && [value isKindOfClass:NSNumber.class]) {
			*bytes = value.unsignedLongLongValue;
			return YES;
		}
		if (resourceError) lastError = resourceError;
	}
	if (outError) *outError = lastError;
	return NO;
}

static MatterCacheSizeResult MatterCalculateCacheSize(MatterCacheRootResolution *rootResolution) {
	MatterCacheSizeResult result = { 0 };
	__block MatterCacheErrorSummary enumeratorErrors = { 0 };
	result.available = rootResolution.rootsAccepted > 0;
	for (MatterCacheRoot *root in MatterNonOverlappingRoots(rootResolution.roots)) {
		if (!MatterExistingRootIsSafe(root, rootResolution, &result.errors)) continue;

		NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager
			enumeratorAtURL:root.url
			includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey,
				NSURLTotalFileAllocatedSizeKey, NSURLFileAllocatedSizeKey, NSURLFileSizeKey]
			options:0
			errorHandler:^BOOL(NSURL *url, NSError *error) {
				MatterCacheRecordError(&enumeratorErrors, error, @"enumerate", root.label, MatterCacheErrorCategoryOther);
				return YES;
			}];
		if (!enumerator) {
			MatterCacheRecordError(&result.errors, nil, @"enumerate", root.label, MatterCacheErrorCategoryOther);
			continue;
		}

		for (NSURL *url in enumerator) {
			@autoreleasepool {
				NSString *path = url.path.stringByStandardizingPath;
				if (!MatterPathIsWithin(path, root.url.path) || [path isEqualToString:root.url.path]) {
					[enumerator skipDescendants];
					MatterCacheRecordError(&result.errors, nil, @"enumerate", root.label, MatterCacheErrorCategoryInvalidPath);
					continue;
				}

				NSNumber *isSymbolicLink = nil;
				NSNumber *isDirectory = nil;
				NSError *resourceError = nil;
				if (![url getResourceValue:&isSymbolicLink forKey:NSURLIsSymbolicLinkKey error:&resourceError]) {
					[enumerator skipDescendants];
					MatterCacheRecordError(&result.errors, resourceError, @"resourceValues", root.label, MatterCacheErrorCategoryOther);
					continue;
				}
				if (isSymbolicLink.boolValue) {
					[enumerator skipDescendants];
					continue;
				}
				if (![url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:&resourceError]) {
					[enumerator skipDescendants];
					MatterCacheRecordError(&result.errors, resourceError, @"resourceValues", root.label, MatterCacheErrorCategoryOther);
					continue;
				}
				if (isDirectory.boolValue) continue;

				uint64_t bytes = 0;
				NSError *sizeError = nil;
				if (!MatterFileSize(url, &bytes, &sizeError)) {
					MatterCacheRecordError(&result.errors, sizeError, @"resourceValues", root.label, MatterCacheErrorCategoryOther);
					continue;
				}
				if (UINT64_MAX - result.bytes < bytes) result.bytes = UINT64_MAX;
				else result.bytes += bytes;
			}
		}
	}
	MatterCacheMergeErrors(&result.errors, enumeratorErrors);
	result.available = rootResolution.rootsAccepted > 0;
	result.rootsAccepted = rootResolution.rootsAccepted;
	result.rootsSkippedUnsafe = rootResolution.rootsSkippedUnsafe;
	return result;
}

static void MatterCacheClearRoots(MatterCacheRootResolution *rootResolution, MatterCacheErrorSummary *errors) {
	NSFileManager *fileManager = NSFileManager.defaultManager;
	for (MatterCacheRoot *root in rootResolution.roots) {
		if (!MatterExistingRootIsSafe(root, rootResolution, errors)) continue;

		NSError *listingError = nil;
		NSArray<NSURL *> *children = [fileManager contentsOfDirectoryAtURL:root.url
			includingPropertiesForKeys:@[NSURLIsSymbolicLinkKey] options:0 error:&listingError];
		if (!children) {
			MatterCacheRecordError(errors, listingError, @"enumerate", root.label, MatterCacheErrorCategoryOther);
			continue;
		}

		for (NSURL *child in children) {
			NSString *childPath = child.path.stringByStandardizingPath;
			if (!MatterPathIsWithin(childPath, root.url.path) || [childPath isEqualToString:root.url.path]) {
				MatterCacheRecordError(errors, nil, @"enumerate", root.label, MatterCacheErrorCategoryInvalidPath);
				continue;
			}
			BOOL containsAnotherRoot = NO;
			for (MatterCacheRoot *otherRoot in rootResolution.roots) {
				if (otherRoot != root && MatterPathIsWithin(otherRoot.url.path, childPath)) {
					containsAnotherRoot = YES;
					break;
				}
			}
			if (containsAnotherRoot) continue;

			NSError *statError = nil;
			NSDictionary *attributes = [fileManager attributesOfItemAtPath:childPath error:&statError];
			if (!attributes) {
				MatterCacheRecordError(errors, statError, @"stat", root.label, MatterCacheErrorCategoryOther);
				continue;
			}
			if ([attributes[NSFileType] isEqualToString:NSFileTypeSymbolicLink]) continue;

			NSNumber *isSymbolicLink = nil;
			NSError *resourceError = nil;
			if (![child getResourceValue:&isSymbolicLink forKey:NSURLIsSymbolicLinkKey error:&resourceError]) {
				MatterCacheRecordError(errors, resourceError, @"resourceValues", root.label, MatterCacheErrorCategoryOther);
				continue;
			}
			if (isSymbolicLink.boolValue) continue;

			NSError *removeError = nil;
			if (![fileManager removeItemAtURL:child error:&removeError]) {
				MatterCacheRecordError(errors, removeError, @"remove", root.label, MatterCacheErrorCategoryOther);
			}
		}
	}
}

static MatterCacheClearResult MatterClearCache(void) {
	MatterCacheClearResult result = { 0 };
	MatterCacheRootResolution *rootResolution = MatterApprovedCacheRoots();
	MatterCacheSizeResult before = MatterCalculateCacheSize(rootResolution);
	result.bytesBefore = before.bytes;
	MatterCacheMergeErrors(&result.errors, before.errors);
	MatterCacheClearRoots(rootResolution, &result.errors);
	@try {
		NSURLCache *urlCache = [NSURLCache sharedURLCache];
		if (urlCache) [urlCache removeAllCachedResponses];
		else MatterCacheRecordError(&result.errors, nil, @"urlCache", @"urlCache", MatterCacheErrorCategoryOther);
	} @catch (NSException *exception) {
		MatterCacheRecordException(&result.errors, exception, @"urlCache", @"urlCache");
	}

	MatterCacheSizeResult after = MatterCalculateCacheSize(rootResolution);
	result.bytesAfter = after.bytes;
	MatterCacheMergeErrors(&result.errors, after.errors);
	result.bytesFreed = result.bytesBefore > result.bytesAfter ? result.bytesBefore - result.bytesAfter : 0;
	result.rootsAccepted = rootResolution.rootsAccepted;
	result.rootsSkippedUnsafe = rootResolution.rootsSkippedUnsafe;
	return result;
}

static void MatterAttemptStartupClear(void) {
	dispatch_once(&MatterStartupClearOnce, ^{
		if (!MatterClearCacheOnStartupEnabled()) return;
		MATTER_CACHE_LOG("startup clear scheduled");
		BOOL started = [MatterCacheManager asynchronouslyClearCacheWithCompletion:^(MatterCacheClearResult result) {
			NSString *counts = MatterCacheErrorCounts(result.errors);
			MATTER_CACHE_LOG("startup clear complete freedBytes=%{public}llu rootsAccepted=%{public}lu rootsSkippedUnsafe=%{public}lu %{public}s",
				(unsigned long long)result.bytesFreed, (unsigned long)result.rootsAccepted,
				(unsigned long)result.rootsSkippedUnsafe, counts.UTF8String);
		}];
		if (!started) MATTER_CACHE_LOG("startup clear skipped reason=clearInProgress");
	});
}

__attribute__((constructor)) static void MatterCacheInstallStartupObserver(void) {
	dispatch_async(dispatch_get_main_queue(), ^{
		UIApplication *application = UIApplication.sharedApplication;
		NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
		[center addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:nil
			usingBlock:^(__unused NSNotification *notification) { MatterAttemptStartupClear(); }];
		[center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil
			usingBlock:^(__unused NSNotification *notification) { MatterAttemptStartupClear(); }];
		if (application.applicationState == UIApplicationStateActive ||
			application.applicationState == UIApplicationStateBackground) {
			MatterAttemptStartupClear();
		}
	});
}

@implementation MatterCacheManager

+ (void)asynchronouslyCalculateCacheSizeWithCompletion:(void (^)(MatterCacheSizeResult))completion {
	MATTER_CACHE_LOG("size calculation begin");
	dispatch_async(MatterCacheQueue(), ^{
		MatterCacheSizeResult result = { 0 };
		@try {
			MatterCacheRootResolution *rootResolution = MatterApprovedCacheRoots();
			result = MatterCalculateCacheSize(rootResolution);
		} @catch (NSException *exception) {
			MatterCacheRecordException(&result.errors, exception, @"recalculate", @"caches");
		}
		NSString *counts = MatterCacheErrorCounts(result.errors);
		MATTER_CACHE_LOG("size calculation complete bytes=%{public}llu rootsAccepted=%{public}lu rootsSkippedUnsafe=%{public}lu %{public}s",
			(unsigned long long)result.bytes, (unsigned long)result.rootsAccepted,
			(unsigned long)result.rootsSkippedUnsafe, counts.UTF8String);
		if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
	});
}

+ (BOOL)asynchronouslyClearCacheWithCompletion:(void (^)(MatterCacheClearResult))completion {
	@synchronized(self) {
		if (MatterCacheClearing) return NO;
		MatterCacheClearing = YES;
	}

	MATTER_CACHE_LOG("clear begin");
	dispatch_async(MatterCacheQueue(), ^{
		MatterCacheClearResult result = { 0 };
		@try {
			result = MatterClearCache();
		} @catch (NSException *exception) {
			MatterCacheRecordException(&result.errors, exception, @"unknown", @"caches");
		}
		@synchronized(self) { MatterCacheClearing = NO; }
		NSString *counts = MatterCacheErrorCounts(result.errors);
		MATTER_CACHE_LOG("clear complete bytesBefore=%{public}llu bytesAfter=%{public}llu bytesFreed=%{public}llu rootsAccepted=%{public}lu rootsSkippedUnsafe=%{public}lu %{public}s",
			(unsigned long long)result.bytesBefore, (unsigned long long)result.bytesAfter,
			(unsigned long long)result.bytesFreed, (unsigned long)result.rootsAccepted,
			(unsigned long)result.rootsSkippedUnsafe, counts.UTF8String);
		if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
	});
	return YES;
}

+ (BOOL)isClearInProgress {
	@synchronized(self) { return MatterCacheClearing; }
}

@end
