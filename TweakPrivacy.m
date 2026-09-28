#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <stdbool.h>
#import <stdlib.h>
#import <string.h>

#import "MatterPreferences.h"

#ifndef MATTER_TELEMETRY_DISCOVERY
#define MATTER_TELEMETRY_DISCOVERY 0
#endif

typedef enum {
	MatterTelemetryObject,
	MatterTelemetryUInt64,
	MatterTelemetryInt64,
	MatterTelemetryBool
} MatterTelemetryArgumentKind;

static IMP MatterOriginalAdDelivery;
static IMP MatterOriginalAdInsertion;
static IMP MatterOriginalAnalyticsEvent;
static IMP MatterOriginalAnalyticsEventImmediately;
#if MATTER_TELEMETRY_DISCOVERY
static IMP MatterOriginalAdViewpoint;
#endif
static unsigned long long MatterBlockedAdDeliveryCount;
static unsigned long long MatterBlockedAdInsertionCount;
static unsigned long long MatterBlockedAnalyticsEventCount;
static unsigned long long MatterBlockedAnalyticsImmediateCount;

static void MatterRuntimeLog(BOOL discovery, const char *message, const char *category,
							 const char *className, const char *selectorName) {
	if (MatterDebugLoggingEnabled()) {
		if (discovery) {
			os_log(OS_LOG_DEFAULT,
				   "[Matter:Telemetry] %{public}s category=%{public}s class=%{public}s selector=%{public}s",
				   message, category, className, selectorName);
		} else {
			os_log(OS_LOG_DEFAULT,
				   "[Matter:Privacy] %{public}s category=%{public}s class=%{public}s selector=%{public}s",
				   message, category, className, selectorName);
		}
	}
}

static void MatterLogBlocked(const char *category, const char *className,
							 const char *selectorName, unsigned long long *counter) {
	if (!MatterDebugLoggingEnabled()) return;
	unsigned long long calls = __atomic_add_fetch(counter, 1ULL, __ATOMIC_RELAXED);
	if (calls == 1 || calls % 100 == 0) {
		os_log(OS_LOG_DEFAULT,
			   "[Matter:Privacy] blocked category=%{public}s class=%{public}s selector=%{public}s calls=%{public}llu",
			   category, className, selectorName, calls);
	}
}

static const char *MatterSkipTypeQualifiers(const char *type) {
	while (type && strchr("rnNoORV", *type)) type++;
	return type;
}

static BOOL MatterTypeMatches(const char *type, MatterTelemetryArgumentKind kind) {
	type = MatterSkipTypeQualifiers(type);
	if (!type) return NO;

	char expectedCode = '@';
	NSUInteger expectedSize = sizeof(id);
	switch (kind) {
		case MatterTelemetryObject:
			expectedCode = '@';
			break;
		case MatterTelemetryUInt64:
			expectedCode = 'Q';
			expectedSize = sizeof(unsigned long long);
			break;
		case MatterTelemetryInt64:
			expectedCode = 'q';
			expectedSize = sizeof(long long);
			break;
		case MatterTelemetryBool:
			expectedCode = 'B';
			expectedSize = sizeof(bool);
			break;
	}

	if (*type != expectedCode) return NO;
	NSUInteger actualSize = 0;
	NSGetSizeAndAlignment(type, &actualSize, NULL);
	return actualSize == expectedSize;
}

static BOOL MatterTelemetryMethodMatches(Method method,
										 const MatterTelemetryArgumentKind *arguments,
										 NSUInteger argumentCount) {
	if (!method || method_getNumberOfArguments(method) != argumentCount + 2) return NO;

	char *returnType = method_copyReturnType(method);
	const char *unqualifiedReturnType = MatterSkipTypeQualifiers(returnType);
	BOOL matches = unqualifiedReturnType && *unqualifiedReturnType == 'v';
	free(returnType);
	if (!matches) return NO;

	for (NSUInteger index = 0; index < argumentCount; index++) {
		char *argumentType = method_copyArgumentType(method, (unsigned int)index + 2);
		matches = MatterTypeMatches(argumentType, arguments[index]);
		free(argumentType);
		if (!matches) return NO;
	}
	return YES;
}

static BOOL MatterClassDefinesMethod(Class cls, SEL selector) {
	unsigned int count = 0;
	Method *methods = class_copyMethodList(cls, &count);
	BOOL found = NO;
	for (unsigned int index = 0; index < count; index++) {
		if (method_getName(methods[index]) == selector) {
			found = YES;
			break;
		}
	}
	free(methods);
	return found;
}

static BOOL MatterInstallRuntimeHook(const char *runtimeClassName, const char *selectorName,
									 const char *category, BOOL discovery,
								   const MatterTelemetryArgumentKind *arguments,
								   NSUInteger argumentCount, IMP replacement, IMP *original) {
	Class cls = objc_getClass(runtimeClassName);
	SEL selector = sel_registerName(selectorName);
	if (!cls) {
		MatterRuntimeLog(discovery, "hook skipped reason=classUnavailable", category, runtimeClassName, selectorName);
		return NO;
	}

	Method method = class_getInstanceMethod(cls, selector);
	if (!method) {
		MatterRuntimeLog(discovery, "hook skipped reason=methodUnavailable", category, runtimeClassName, selectorName);
		return NO;
	}
	if (!MatterTelemetryMethodMatches(method, arguments, argumentCount)) {
		MatterRuntimeLog(discovery, "hook skipped reason=signatureMismatch", category, runtimeClassName, selectorName);
		return NO;
	}

	IMP implementation = method_getImplementation(method);
	if (!implementation || implementation == replacement) {
		MatterRuntimeLog(discovery, "hook skipped reason=implementationUnavailable", category, runtimeClassName, selectorName);
		return NO;
	}

	BOOL installed = NO;
	if (MatterClassDefinesMethod(cls, selector)) {
		*original = method_setImplementation(method, replacement);
		installed = *original != NULL;
	} else {
		*original = implementation;
		installed = class_addMethod(cls, selector, replacement, method_getTypeEncoding(method));
	}

	if (!installed) {
		*original = NULL;
		MatterRuntimeLog(discovery, "hook skipped reason=installFailed", category, runtimeClassName, selectorName);
		return NO;
	}
	MatterRuntimeLog(discovery, "hook installed", category, runtimeClassName, selectorName);
	return YES;
}

#if MATTER_TELEMETRY_DISCOVERY
static void MatterAdViewpointHook(id self, SEL _cmd, id mediaView, unsigned long long itemType,
								  id modelPK, id containerOrAdPK, id adPlatformMetadata,
								  id inventorySource, long long viewpointLevel,
								  long long currentItemIndex, bool hasAudio) {
	MatterRuntimeLog(YES, "fired", "ad", class_getName(object_getClass(self)), sel_getName(_cmd));
	((void (*)(id, SEL, id, unsigned long long, id, id, id, id, long long, long long, bool))MatterOriginalAdViewpoint)(
		self, _cmd, mediaView, itemType, modelPK, containerOrAdPK, adPlatformMetadata,
		inventorySource, viewpointLevel, currentItemIndex, hasAudio);
}
#endif

static void MatterAdDeliveryHook(id self, SEL _cmd, id sponsoredItems, id containerModule,
								 id surfaceExtraLoggingDicts, bool isPrefetch,
								 unsigned long long deliveryContext, id recentSeenItemIDs,
								 id surfaceSnapshot, id perfLoggingDict, id extraLoggingDict) {
	if (MatterBlockAdTelemetryEnabled()) {
		MatterLogBlocked("adTelemetry", class_getName(object_getClass(self)), sel_getName(_cmd),
						 &MatterBlockedAdDeliveryCount);
		return;
	}
	((void (*)(id, SEL, id, id, id, bool, unsigned long long, id, id, id, id))MatterOriginalAdDelivery)(
		self, _cmd, sponsoredItems, containerModule, surfaceExtraLoggingDicts, isPrefetch,
		deliveryContext, recentSeenItemIDs, surfaceSnapshot, perfLoggingDict, extraLoggingDict);
}

static void MatterAdInsertionHook(id self, SEL _cmd, id sponsoredItem, id containerModule,
								  long long insertedPosition, id surfaceExtraLoggingDict,
								  id surfaceSnapshot, id perfLoggingDict) {
	if (MatterBlockAdTelemetryEnabled()) {
		MatterLogBlocked("adTelemetry", class_getName(object_getClass(self)), sel_getName(_cmd),
						 &MatterBlockedAdInsertionCount);
		return;
	}
	((void (*)(id, SEL, id, id, long long, id, id, id))MatterOriginalAdInsertion)(
		self, _cmd, sponsoredItem, containerModule, insertedPosition,
		surfaceExtraLoggingDict, surfaceSnapshot, perfLoggingDict);
}

static void MatterAnalyticsEventHook(id self, SEL _cmd, id event) {
	if (MatterBlockAnalyticsEnabled()) {
		MatterLogBlocked("analytics", class_getName(object_getClass(self)), sel_getName(_cmd),
						 &MatterBlockedAnalyticsEventCount);
		return;
	}
	((void (*)(id, SEL, id))MatterOriginalAnalyticsEvent)(self, _cmd, event);
}

static void MatterAnalyticsEventImmediatelyHook(id self, SEL _cmd, id event) {
	if (MatterBlockAnalyticsEnabled()) {
		MatterLogBlocked("analytics", class_getName(object_getClass(self)), sel_getName(_cmd),
						 &MatterBlockedAnalyticsImmediateCount);
		return;
	}
	((void (*)(id, SEL, id))MatterOriginalAnalyticsEventImmediately)(self, _cmd, event);
}

__attribute__((constructor)) static void MatterInstallPrivacyHooks(void) {
	static const MatterTelemetryArgumentKind adDeliveryArguments[] = {
		MatterTelemetryObject, MatterTelemetryObject, MatterTelemetryObject,
		MatterTelemetryBool, MatterTelemetryUInt64, MatterTelemetryObject,
		MatterTelemetryObject, MatterTelemetryObject, MatterTelemetryObject
	};
	static const MatterTelemetryArgumentKind adInsertionArguments[] = {
		MatterTelemetryObject, MatterTelemetryObject, MatterTelemetryInt64,
		MatterTelemetryObject, MatterTelemetryObject, MatterTelemetryObject
	};
	static const MatterTelemetryArgumentKind analyticsArguments[] = { MatterTelemetryObject };

	MatterInstallRuntimeHook(
		"IGAdPlatformLogger_objc",
		"logDeliveryEventForSponsoredItems:containerModule:surfaceExtraLoggingDicts:isPrefetch:deliveryContext:recentSeenItemIDs:surfaceSnapshot:perfLoggingDict:extraLoggingDict:",
		"adTelemetry", NO, adDeliveryArguments, sizeof(adDeliveryArguments) / sizeof(adDeliveryArguments[0]),
		(IMP)MatterAdDeliveryHook, &MatterOriginalAdDelivery);
	MatterInstallRuntimeHook(
		"IGAdPlatformLogger_objc",
		"logInsertionSuccessForSponsoredItem:containerModule:insertedPosition:surfaceExtraLoggingDict:surfaceSnapshot:perfLoggingDict:",
		"adTelemetry", NO, adInsertionArguments, sizeof(adInsertionArguments) / sizeof(adInsertionArguments[0]),
		(IMP)MatterAdInsertionHook, &MatterOriginalAdInsertion);
	MatterInstallRuntimeHook(
		"IGApplicationAnalytics", "logEvent:", "analytics", NO, analyticsArguments, 1,
		(IMP)MatterAnalyticsEventHook, &MatterOriginalAnalyticsEvent);
	MatterInstallRuntimeHook(
		"IGApplicationAnalytics", "logEventImmediately:", "analytics", NO, analyticsArguments, 1,
		(IMP)MatterAnalyticsEventImmediatelyHook, &MatterOriginalAnalyticsEventImmediately);

#if MATTER_TELEMETRY_DISCOVERY
	static const MatterTelemetryArgumentKind adViewpointArguments[] = {
		MatterTelemetryObject, MatterTelemetryUInt64, MatterTelemetryObject,
		MatterTelemetryObject, MatterTelemetryObject, MatterTelemetryObject,
		MatterTelemetryInt64, MatterTelemetryInt64, MatterTelemetryBool
	};
	MatterInstallRuntimeHook(
		"IGAdInsertionMediaViewTracker",
		"trackViewpointActionForMediaView:itemType:modelPK:containerOrAdPK:adPlatformMetadata:inventorySource:viewpointLevel:currentItemIndex:hasAudio:",
		"unconfirmedAdViewability", YES, adViewpointArguments,
		sizeof(adViewpointArguments) / sizeof(adViewpointArguments[0]),
		(IMP)MatterAdViewpointHook, &MatterOriginalAdViewpoint);
#endif
}
