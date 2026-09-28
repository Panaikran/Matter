#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <os/log.h>
#import "MatterPreferences.h"

%config(generator=internal);

#ifndef MATTER_EXPERIMENTAL_FILTERING
#define MATTER_EXPERIMENTAL_FILTERING 0
#endif
#define MATTER_MAX_LOGGED_COLLECTION_ELEMENTS 3

#if MATTER_DEBUG_LOGGING
#define MATTER_LOG(...) do { if (MatterDebugLoggingEnabled()) os_log(OS_LOG_DEFAULT, "[Matter] " __VA_ARGS__); } while (0)
#else
#define MATTER_LOG(...) do { } while (0)
#endif

#if MATTER_DEBUG_LOGGING || MATTER_EXPERIMENTAL_FILTERING
typedef enum {
	MatterCollectionKindNone,
	MatterCollectionKindArray,
	MatterCollectionKindOrderedSet,
	MatterCollectionKindSet,
	MatterCollectionKindDictionary
} MatterCollectionKind;

typedef enum {
	MatterProtocolStatusUnknown,
	MatterProtocolStatusNo,
	MatterProtocolStatusYes
} MatterProtocolStatus;

typedef struct {
	BOOL safelyEnumerable;
	BOOL ordered;
	BOOL allElementsSponsored;
	NSUInteger count;
} MatterCollectionInspection;

static const char *MatterRuntimeClassName(id object) {
	if (!object) {
		return "(nil)";
	}

	Class objectClass = object_getClass(object);
	const char *className = objectClass ? class_getName(objectClass) : NULL;
	return className ? className : "(unknown)";
}

static BOOL MatterClassIsSubclassOfClass(Class candidate, Class baseClass) {
	if (!candidate || !baseClass) {
		return NO;
	}

	for (Class current = candidate; current; current = class_getSuperclass(current)) {
		if (current == baseClass) {
			return YES;
		}
	}

	return NO;
}

static BOOL MatterClassHasInstanceMethod(Class cls, SEL selector) {
	return cls && selector && class_getInstanceMethod(cls, selector) != NULL;
}

static MatterCollectionKind MatterCollectionKindForObject(id object) {
	if (!object) {
		return MatterCollectionKindNone;
	}

	Class objectClass = object_getClass(object);
	Class arrayClass = objc_getClass("NSArray");
	if (arrayClass && MatterClassIsSubclassOfClass(objectClass, arrayClass)) {
		return MatterCollectionKindArray;
	}
	Class orderedSetClass = objc_getClass("NSOrderedSet");
	if (orderedSetClass && MatterClassIsSubclassOfClass(objectClass, orderedSetClass)) {
		return MatterCollectionKindOrderedSet;
	}
	Class setClass = objc_getClass("NSSet");
	if (setClass && MatterClassIsSubclassOfClass(objectClass, setClass)) {
		return MatterCollectionKindSet;
	}
	Class dictionaryClass = objc_getClass("NSDictionary");
	if (dictionaryClass && MatterClassIsSubclassOfClass(objectClass, dictionaryClass)) {
		return MatterCollectionKindDictionary;
	}
	return MatterCollectionKindNone;
}

static BOOL MatterCollectionHasRequiredMethods(id object, MatterCollectionKind kind) {
	Class objectClass = object ? object_getClass(object) : Nil;
	if (!MatterClassHasInstanceMethod(objectClass, @selector(count))) {
		return NO;
	}

	if (kind == MatterCollectionKindArray || kind == MatterCollectionKindOrderedSet) {
		return MatterClassHasInstanceMethod(objectClass, @selector(objectAtIndex:));
	}
	return MatterClassHasInstanceMethod(objectClass, @selector(objectEnumerator));
}

static NSUInteger MatterCollectionCount(id object, MatterCollectionKind kind) {
	switch (kind) {
		case MatterCollectionKindArray: return [(NSArray *)object count];
		case MatterCollectionKindOrderedSet: return [(NSOrderedSet *)object count];
		case MatterCollectionKindSet: return [(NSSet *)object count];
		case MatterCollectionKindDictionary: return [(NSDictionary *)object count];
		default: return 0;
	}
}

static id MatterCollectionElementAtIndex(id object, MatterCollectionKind kind, NSUInteger index,
										 NSEnumerator **enumerator) {
	switch (kind) {
		case MatterCollectionKindArray:
			return [(NSArray *)object objectAtIndex:index];
		case MatterCollectionKindOrderedSet:
			return [(NSOrderedSet *)object objectAtIndex:index];
		case MatterCollectionKindSet:
			if (!*enumerator) *enumerator = [(NSSet *)object objectEnumerator];
			break;
		case MatterCollectionKindDictionary:
			if (!*enumerator) *enumerator = [(NSDictionary *)object objectEnumerator];
			break;
		default:
			return nil;
	}

	if (!*enumerator ||
	    !MatterClassHasInstanceMethod(object_getClass(*enumerator), @selector(nextObject))) {
		return nil;
	}
	return [*enumerator nextObject];
}

static MatterProtocolStatus MatterProtocolStatusForClass(Class cls, const char *protocolName) {
	if (!cls || !protocolName) {
		return MatterProtocolStatusUnknown;
	}
	Protocol *protocol = objc_getProtocol(protocolName);
	if (!protocol) {
		return MatterProtocolStatusUnknown;
	}
	return class_conformsToProtocol(cls, protocol) ? MatterProtocolStatusYes : MatterProtocolStatusNo;
}

static const char *MatterProtocolStatusName(MatterProtocolStatus status) {
	switch (status) {
		case MatterProtocolStatusYes: return "YES";
		case MatterProtocolStatusNo: return "NO";
		default: return "UNKNOWN";
	}
}

static BOOL MatterClassIsVerifiedSponsoredWrapper(Class cls) {
	static const char *wrapperNames[] = {
		"IGNetegoAdPlatformSponsoredItemWrapper",
		"IGMultiAdsAdPlatformSponsoredItemWrapper",
		"IGNewsStoryAdPlatformSponsoredItemWrapper"
	};
	if (!cls) {
		return NO;
	}

	for (NSUInteger index = 0; index < sizeof(wrapperNames) / sizeof(wrapperNames[0]); index++) {
		Class wrapperClass = objc_getClass(wrapperNames[index]);
		if (wrapperClass && MatterClassIsSubclassOfClass(cls, wrapperClass)) {
			return YES;
		}
	}
	return NO;
}

static MatterCollectionInspection MatterInspectObject(const char *label, id object) {
	MatterCollectionInspection inspection = { NO, NO, NO, 0 };
	if (!object) {
		MATTER_LOG("%{public}s class=%{public}s", label, MatterRuntimeClassName(object));
		return inspection;
	}

	MatterCollectionKind kind = MatterCollectionKindForObject(object);
	if (kind == MatterCollectionKindNone) {
		MATTER_LOG("%{public}s class=%{public}s", label, MatterRuntimeClassName(object));
		return inspection;
	}
	if (!MatterCollectionHasRequiredMethods(object, kind)) {
		MATTER_LOG("%{public}s class=%{public}s collection=not-safely-enumerable",
			   label, MatterRuntimeClassName(object));
		return inspection;
	}

	@try {
		inspection.count = MatterCollectionCount(object, kind);
		inspection.ordered = kind == MatterCollectionKindArray || kind == MatterCollectionKindOrderedSet;
		inspection.allElementsSponsored = inspection.count > 0 &&
			inspection.count <= MATTER_MAX_LOGGED_COLLECTION_ELEMENTS;
		MATTER_LOG("%{public}s collection class=%{public}s count=%{public}lu",
			   label, MatterRuntimeClassName(object), (unsigned long)inspection.count);

		NSUInteger elementLimit = MIN(inspection.count, MATTER_MAX_LOGGED_COLLECTION_ELEMENTS);
		NSEnumerator *enumerator = nil;
		for (NSUInteger index = 0; index < elementLimit; index++) {
			id element = MatterCollectionElementAtIndex(object, kind, index, &enumerator);
			if (!element) {
				inspection.allElementsSponsored = NO;
				MATTER_LOG("%{public}s element enumeration stopped; continuing unchanged", label);
				return inspection;
			}

			Class elementClass = object_getClass(element);
			MatterProtocolStatus sponsoredProtocol = MatterProtocolStatusForClass(
				elementClass, "IGAdPlatformSponsoredItemInfoProviding");
			MatterProtocolStatus unitItemProtocol = MatterProtocolStatusForClass(
				elementClass, "IGUnitItemInformationProviding");
			BOOL verifiedWrapper = MatterClassIsVerifiedSponsoredWrapper(elementClass);
			BOOL strongSponsoredDiscriminator = sponsoredProtocol == MatterProtocolStatusYes || verifiedWrapper;
			if (!strongSponsoredDiscriminator) {
				inspection.allElementsSponsored = NO;
			}

			MATTER_LOG("%{public}s element[%{public}lu] class=%{public}s IGAdPlatformSponsoredItemInfoProviding=%{public}s IGUnitItemInformationProviding=%{public}s verifiedSponsoredWrapper=%{public}s",
				   label, (unsigned long)index, MatterRuntimeClassName(element),
				   MatterProtocolStatusName(sponsoredProtocol), MatterProtocolStatusName(unitItemProtocol),
				   verifiedWrapper ? "YES" : "NO");
		}

		inspection.safelyEnumerable = YES;
	} @catch (__unused NSException *exception) {
		inspection.safelyEnumerable = NO;
		inspection.allElementsSponsored = NO;
		MATTER_LOG("%{public}s collection inspection aborted; continuing unchanged", label);
	}
	return inspection;
}

#if MATTER_EXPERIMENTAL_FILTERING
static BOOL MatterInspectionIsConfidentlySponsored(MatterCollectionInspection inspection) {
	return inspection.safelyEnumerable && inspection.ordered && inspection.count > 0 &&
	       inspection.count <= MATTER_MAX_LOGGED_COLLECTION_ELEMENTS && inspection.allElementsSponsored;
}
#endif

#endif

%hook _TtC15IGBCNAdsManager37BCNMainFeedAdsInsertionSurfaceHandler

- (id)prepareSurfaceStateAndFilterSponsoredItems:(id)sponsoredItems
							deliveryContext:(unsigned long long)deliveryContext
								acpContext:(id)acpContext {
	#if MATTER_DEBUG_LOGGING
	MATTER_LOG("prepareSurfaceStateAndFilterSponsoredItems:deliveryContext:acpContext: entered");
	#endif
	#if MATTER_EXPERIMENTAL_FILTERING
	MatterCollectionInspection inputInspection = MatterInspectObject("sponsoredItems", sponsoredItems);
	#elif MATTER_DEBUG_LOGGING
	if (MatterDebugLoggingEnabled()) (void)MatterInspectObject("sponsoredItems", sponsoredItems);
	#endif
	#if MATTER_DEBUG_LOGGING
	if (MatterDebugLoggingEnabled()) (void)MatterInspectObject("acpContext", acpContext);
	#endif

	id result = %orig(sponsoredItems, deliveryContext, acpContext);
	#if MATTER_DEBUG_LOGGING
	if (!result) {
		MATTER_LOG("prepare result isNil=%{public}s class=%{public}s", "YES", MatterRuntimeClassName(result));
	} else {
		MATTER_LOG("prepare result isNil=%{public}s class=%{public}s", "NO", MatterRuntimeClassName(result));
	}
	#endif
	#if MATTER_EXPERIMENTAL_FILTERING
	MatterCollectionInspection resultInspection = MatterInspectObject("prepare result", result);
	#elif MATTER_DEBUG_LOGGING
	if (MatterDebugLoggingEnabled()) (void)MatterInspectObject("prepare result", result);
	#endif
	#if MATTER_EXPERIMENTAL_FILTERING
	if (MatterBlockSponsoredPostsEnabled() &&
	    MatterInspectionIsConfidentlySponsored(inputInspection) &&
	    MatterInspectionIsConfidentlySponsored(resultInspection)) {
		MATTER_LOG("EXPERIMENTAL FILTER: suppressing sponsored prepare result count=%{public}lu",
			   (unsigned long)resultInspection.count);
		return nil;
	}
	#endif
	return result;
}

- (void)receivedSponsoredItems:(id)sponsoredItems intentAwareData:(id)intentAwareData {
	#if MATTER_DEBUG_LOGGING
	if (MatterDebugLoggingEnabled()) {
		MATTER_LOG("receivedSponsoredItems:intentAwareData: entered");
		(void)MatterInspectObject("sponsoredItems", sponsoredItems);
		(void)MatterInspectObject("intentAwareData", intentAwareData);
	}
	#endif
	%orig(sponsoredItems, intentAwareData);
}

%end

%hook _TtC11BCNMainFeed29BCNMainFeedAdsAwareDataSource

- (void)insert:(id)item atInsertionIndex:(long long)insertionIndex {
	#if MATTER_DEBUG_LOGGING
	if (MatterDebugLoggingEnabled()) {
		Class itemClass = item ? object_getClass(item) : Nil;
		MatterProtocolStatus protocolStatus = MatterProtocolStatusForClass(
			itemClass, "IGAdPlatformSponsoredItemInfoProviding");
		MATTER_LOG("insert:atInsertionIndex: itemClass=%{public}s index=%{public}lld IGAdPlatformSponsoredItemInfoProviding=%{public}s verifiedSponsoredWrapper=%{public}s",
			   MatterRuntimeClassName(item), insertionIndex, MatterProtocolStatusName(protocolStatus),
			   MatterClassIsVerifiedSponsoredWrapper(itemClass) ? "YES" : "NO");
		MatterCollectionInspection insertionInspection = MatterInspectObject("insert", item);
		if (!insertionInspection.safelyEnumerable) {
			MATTER_LOG("insert value is not safely enumerable as a Foundation collection; proceeding unchanged");
		}
	}
	#endif
	%orig(item, insertionIndex);
}

%end

%ctor {
	#if MATTER_DEBUG_LOGGING
	MATTER_LOG("runtime hooks loaded; experimental filtering=%{public}s",
		   MATTER_EXPERIMENTAL_FILTERING ? "ON" : "OFF");
	#endif
}
