#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <dispatch/dispatch.h>
#import <string.h>

#import "MatterPreferences.h"
#import "MatterSettingsViewController.h"

#define MATTER_SETTINGS_LOG(...) do { if (MatterDebugLoggingEnabled()) os_log(OS_LOG_DEFAULT, "[Matter:UI] " __VA_ARGS__); } while (0)

static NSString *const MatterSettingsEntryIdentifier = @"com.panaikran.matter.settings-entry";
static NSString *const MatterSettingsEntryReuseIdentifier = @"com.panaikran.matter.settings-entry-cell";
static const NSUInteger MatterSettingsEntryIndex = 4;
static const CGFloat MatterSettingsEntryHeight = 56.0;

@interface MatterSettingsEntryMarker : NSObject
@end

@implementation MatterSettingsEntryMarker

- (id)diffIdentifier {
	return MatterSettingsEntryIdentifier;
}

- (BOOL)isEqualToDiffableObject:(id)object {
	return object && object_getClass(object) == object_getClass(self);
}

@end

@interface MatterSettingsEntryCell : UICollectionViewCell
@end

@implementation MatterSettingsEntryCell

- (instancetype)initWithFrame:(CGRect)frame {
	self = [super initWithFrame:frame];
	if (!self) {
		return nil;
	}

	self.backgroundColor = UIColor.clearColor;
	self.contentView.backgroundColor = UIColor.clearColor;
	self.selectedBackgroundView = [[UIView alloc] initWithFrame:CGRectZero];
	self.selectedBackgroundView.backgroundColor = UIColor.secondarySystemFillColor;

	UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
	title.translatesAutoresizingMaskIntoConstraints = NO;
	title.text = @"Matter";
	title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
	title.adjustsFontForContentSizeCategory = YES;
	title.textColor = UIColor.labelColor;

	UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
	chevron.translatesAutoresizingMaskIntoConstraints = NO;
	chevron.tintColor = UIColor.tertiaryLabelColor;
	chevron.contentMode = UIViewContentModeScaleAspectFit;

	UIView *separator = [[UIView alloc] initWithFrame:CGRectZero];
	separator.translatesAutoresizingMaskIntoConstraints = NO;
	separator.backgroundColor = UIColor.separatorColor;

	[self.contentView addSubview:title];
	[self.contentView addSubview:chevron];
	[self.contentView addSubview:separator];
	[NSLayoutConstraint activateConstraints:@[
		[title.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:20.0],
		[title.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
		[chevron.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16.0],
		[chevron.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
		[chevron.widthAnchor constraintEqualToConstant:12.0],
		[chevron.heightAnchor constraintEqualToConstant:18.0],
		[title.trailingAnchor constraintLessThanOrEqualToAnchor:chevron.leadingAnchor constant:-12.0],
		[separator.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
		[separator.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
		[separator.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
		[separator.heightAnchor constraintEqualToConstant:0.5]
	]];
	return self;
}

@end

static __weak UIViewController *MatterSettingsHostController = nil;
static Class MatterSettingsSectionControllerClass = Nil;
static IMP MatterOriginalObjectsForListAdapter = NULL;
static IMP MatterOriginalSectionControllerForObject = NULL;

static const char *MatterInjectionUnqualifiedType(const char *type) {
	while (type && strchr("rnNoORV", type[0])) {
		type++;
	}
	return type;
}

static BOOL MatterInjectionTypeMatches(const char *actual, const char *expected) {
	actual = MatterInjectionUnqualifiedType(actual);
	expected = MatterInjectionUnqualifiedType(expected);
	if (!actual || !expected) {
		return NO;
	}
	if (expected[0] == '{') {
		return strcmp(actual, expected) == 0;
	}
	if (expected[0] == '@') {
		return actual[0] == '@';
	}
	return actual[0] == expected[0] && actual[1] == '\0';
}

static BOOL MatterInjectionEncodedTypeHasSize(const char *type, NSUInteger expectedSize) {
	type = MatterInjectionUnqualifiedType(type);
	if (!type || !type[0]) {
		return NO;
	}
	NSUInteger size = 0;
	@try {
		NSGetSizeAndAlignment(type, &size, NULL);
	} @catch (__unused NSException *exception) {
		return NO;
	}
	return size == expectedSize;
}

static BOOL MatterInjectionIsIntegerType(const char *type, NSUInteger expectedSize) {
	type = MatterInjectionUnqualifiedType(type);
	return type && type[1] == '\0' && strchr("cCsSiIlLqQ", type[0]) &&
		MatterInjectionEncodedTypeHasSize(type, expectedSize);
}

static BOOL MatterInjectionIsPointerType(const char *type) {
	type = MatterInjectionUnqualifiedType(type);
	return type && (type[0] == '^' || type[0] == '*') &&
		MatterInjectionEncodedTypeHasSize(type, sizeof(void *));
}

static BOOL MatterInjectionMethodMatches(Method method, unsigned int argumentCount,
		const char *returnType, const char *const *argumentTypes) {
	if (!method || method_getNumberOfArguments(method) != argumentCount) {
		return NO;
	}

	char *actualReturnType = method_copyReturnType(method);
	BOOL matches = MatterInjectionTypeMatches(actualReturnType, returnType);
	free(actualReturnType);
	for (unsigned int index = 2; matches && index < argumentCount; index++) {
		char *actualArgumentType = method_copyArgumentType(method, index);
		matches = MatterInjectionTypeMatches(actualArgumentType, argumentTypes[index - 2]);
		free(actualArgumentType);
	}
	return matches;
}

static BOOL MatterInjectionProtocolMethodMatches(Protocol *protocol, SEL selector, const char *encoding) {
	if (!protocol || !selector || !encoding) {
		return NO;
	}
	struct objc_method_description description = protocol_getMethodDescription(protocol, selector, YES, YES);
	return description.name && description.types && strcmp(description.types, encoding) == 0;
}

static BOOL MatterInjectionPrepareMarker(const char **failureStep) {
	Protocol *diffable = objc_getProtocol("IGListDiffable");
	BOOL protocolAvailable = diffable != NULL;
	MATTER_SETTINGS_LOG("contract IGListDiffable protocol=%{public}s", protocolAvailable ? "YES" : "NO");
	if (!protocolAvailable) {
		if (failureStep) {
			*failureStep = "diffableProtocol";
		}
		return NO;
	}
	BOOL protocolMethodsMatch =
		MatterInjectionProtocolMethodMatches(diffable, @selector(diffIdentifier), "@16@0:8") &&
		MatterInjectionProtocolMethodMatches(diffable, @selector(isEqualToDiffableObject:), "B24@0:8@16");
	MATTER_SETTINGS_LOG("contract IGListDiffable methodSignatures=%{public}s",
		protocolMethodsMatch ? "YES" : "NO");
	if (!protocolMethodsMatch) {
		if (failureStep) {
			*failureStep = "diffableProtocolSignatures";
		}
		return NO;
	}

	Class markerClass = MatterSettingsEntryMarker.class;
	Method identifierMethod = class_getInstanceMethod(markerClass, @selector(diffIdentifier));
	Method equalityMethod = class_getInstanceMethod(markerClass, @selector(isEqualToDiffableObject:));
	const char *equalityArguments[] = { "@" };
	BOOL markerMethodSignatures = MatterInjectionMethodMatches(identifierMethod, 2, "@", NULL) &&
		MatterInjectionMethodMatches(equalityMethod, 3, "B", equalityArguments);
	MATTER_SETTINGS_LOG("contract markerMethodSignatures=%{public}s",
		markerMethodSignatures ? "YES" : "NO");
	if (!markerMethodSignatures) {
		if (failureStep) {
			*failureStep = "markerMethodSignatures";
		}
		return NO;
	}
	BOOL conforms = class_conformsToProtocol(markerClass, diffable);
	if (!conforms) {
		conforms = class_addProtocol(markerClass, diffable);
	}
	BOOL verifiedConformance = conforms && class_conformsToProtocol(markerClass, diffable);
	MATTER_SETTINGS_LOG("contract markerDiffableConformance=%{public}s",
		verifiedConformance ? "YES" : "NO");
	if (!verifiedConformance) {
		if (failureStep) {
			*failureStep = "markerDiffableConformance";
		}
		return NO;
	}
	return YES;
}

static id MatterSettingsEntryMarkerInstance(void) {
	static MatterSettingsEntryMarker *marker = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		marker = [[MatterSettingsEntryMarker alloc] init];
	});
	return marker;
}

static BOOL MatterInjectionBaseMethod(Class sectionBase, SEL selector, unsigned int argumentCount,
		const char *returnType, const char *const *argumentTypes, Method *methodOut) {
	Method method = sectionBase ? class_getInstanceMethod(sectionBase, selector) : NULL;
	if (methodOut) {
		*methodOut = method;
	}
	return MatterInjectionMethodMatches(method, argumentCount, returnType, argumentTypes);
}

static id MatterInjectionCollectionContext(id sectionController) {
	SEL selector = NSSelectorFromString(@"collectionContext");
	Method method = class_getInstanceMethod(object_getClass(sectionController), selector);
	if (!sectionController || ![sectionController respondsToSelector:selector] ||
	    !MatterInjectionMethodMatches(method, 2, "@", NULL)) {
		return nil;
	}
	return ((id (*)(id, SEL))objc_msgSend)(sectionController, selector);
}

static BOOL MatterInjectionContextIsValid(id context) {
	Protocol *collectionContext = objc_getProtocol("IGListCollectionContext");
	SEL containerSizeSelector = NSSelectorFromString(@"containerSize");
	SEL dequeueSelector = NSSelectorFromString(@"dequeueReusableCellOfClass:withReuseIdentifier:forSectionController:atIndex:");
	if (!context || !collectionContext ||
	    !class_conformsToProtocol(object_getClass(context), collectionContext) ||
	    !MatterInjectionProtocolMethodMatches(collectionContext, containerSizeSelector, "{CGSize=dd}16@0:8") ||
	    !MatterInjectionProtocolMethodMatches(collectionContext, dequeueSelector, "@48@0:8#16@24@32q40")) {
		return NO;
	}

	const char *dequeueArguments[] = { "#", "@", "@", @encode(NSInteger) };
	Method sizeMethod = class_getInstanceMethod(object_getClass(context), containerSizeSelector);
	Method dequeueMethod = class_getInstanceMethod(object_getClass(context), dequeueSelector);
	return MatterInjectionMethodMatches(sizeMethod, 2, @encode(CGSize), NULL) &&
		MatterInjectionMethodMatches(dequeueMethod, 6, "@", dequeueArguments);
}

static CGSize MatterSettingsEntrySize(id self, SEL selector, NSInteger index) {
	(void)selector;
	if (index != 0) {
		return CGSizeZero;
	}
	id context = MatterInjectionCollectionContext(self);
	if (!MatterInjectionContextIsValid(context)) {
		MATTER_SETTINGS_LOG("Matter section layout unavailable reason=collectionContext");
		return CGSizeZero;
	}
	SEL containerSizeSelector = NSSelectorFromString(@"containerSize");
	CGSize containerSize = ((CGSize (*)(id, SEL))objc_msgSend)(context, containerSizeSelector);
	return CGSizeMake(containerSize.width, MatterSettingsEntryHeight);
}

static NSInteger MatterSettingsEntryNumberOfItems(id self, SEL selector) {
	(void)self;
	(void)selector;
	return 1;
}

static id MatterSettingsEntryCellForItem(id self, SEL selector, NSInteger index) {
	(void)selector;
	if (index != 0) {
		return nil;
	}
	id context = MatterInjectionCollectionContext(self);
	if (!MatterInjectionContextIsValid(context)) {
		MATTER_SETTINGS_LOG("Matter cell unavailable reason=collectionContext");
		return nil;
	}
	SEL dequeueSelector = NSSelectorFromString(@"dequeueReusableCellOfClass:withReuseIdentifier:forSectionController:atIndex:");
	UICollectionViewCell *cell = ((id (*)(id, SEL, Class, id, id, NSInteger))objc_msgSend)(
		context, dequeueSelector, MatterSettingsEntryCell.class, MatterSettingsEntryReuseIdentifier, self, index);
	if (cell && [cell isKindOfClass:MatterSettingsEntryCell.class]) {
		MATTER_SETTINGS_LOG("Matter cell rendered");
		return cell;
	}
	MATTER_SETTINGS_LOG("Matter cell unavailable reason=dequeueFailed");
	return cell;
}

static void MatterPushSettingsController(void) {
	UIViewController *host = MatterSettingsHostController;
	Class settingsClass = objc_getClass("MatterSettingsViewController");
	UINavigationController *navigationController = host.navigationController;
	if (!host || !settingsClass || !navigationController) {
		return;
	}
	UIViewController *topViewController = navigationController.topViewController;
	if ([topViewController isKindOfClass:settingsClass]) {
		return;
	}
	if (topViewController != host) {
		return;
	}
	UIViewController *settingsController = [[settingsClass alloc] init];
	if (!settingsController) {
		return;
	}
	[navigationController pushViewController:settingsController animated:YES];
	MATTER_SETTINGS_LOG("Matter settings pushed");
}

static void MatterDeselectSettingsEntry(id sectionController, NSInteger index) {
	id context = MatterInjectionCollectionContext(sectionController);
	if (!context) {
		MATTER_SETTINGS_LOG("Matter row deselect skipped reason=collectionContextUnavailable");
		return;
	}

	Protocol *collectionContextProtocol = objc_getProtocol("IGListCollectionContext");
	Class contextClass = object_getClass(context);
	BOOL protocolAvailable = collectionContextProtocol != NULL;
	BOOL conforms = protocolAvailable && contextClass &&
		class_conformsToProtocol(contextClass, collectionContextProtocol);
	SEL selector = NSSelectorFromString(@"deselectItemAtIndex:sectionController:animated:");
	struct objc_method_description protocolMethod = { NULL, NULL };
	if (collectionContextProtocol) {
		protocolMethod = protocol_getMethodDescription(collectionContextProtocol, selector, YES, YES);
	}
	BOOL protocolSelectorAvailable = protocolMethod.name != NULL;
	BOOL selectorAvailable = [context respondsToSelector:selector];
	Method method = contextClass ? class_getInstanceMethod(contextClass, selector) : NULL;
	unsigned int argumentCount = method ? method_getNumberOfArguments(method) : 0;
	BOOL argumentCountValid = method && argumentCount == 5;
	char *returnType = method ? method_copyReturnType(method) : NULL;
	char *indexType = argumentCountValid ? method_copyArgumentType(method, 2) : NULL;
	char *sectionControllerType = argumentCountValid ? method_copyArgumentType(method, 3) : NULL;
	char *animatedType = argumentCountValid ? method_copyArgumentType(method, 4) : NULL;
	BOOL returnCompatible = argumentCountValid && MatterInjectionTypeMatches(returnType, "v");
	BOOL indexCompatible = argumentCountValid &&
		MatterInjectionTypeMatches(indexType, @encode(NSInteger));
	BOOL sectionControllerCompatible = argumentCountValid &&
		MatterInjectionTypeMatches(sectionControllerType, "@");
	BOOL animatedCompatible = argumentCountValid &&
		MatterInjectionTypeMatches(animatedType, @encode(BOOL));
	free(returnType);
	free(indexType);
	free(sectionControllerType);
	free(animatedType);

	BOOL signatureValid = protocolSelectorAvailable && conforms && selectorAvailable && method &&
		argumentCountValid && returnCompatible && indexCompatible && sectionControllerCompatible &&
		animatedCompatible;
	MATTER_SETTINGS_LOG("Matter row deselect contextClass=%{public}s protocol=%{public}s conforms=%{public}s selector=%{public}s method=%{public}s argCount=%{public}u return=%{public}s index=%{public}s sectionController=%{public}s animated=%{public}s",
		contextClass ? class_getName(contextClass) : "(nil)",
		protocolAvailable ? "YES" : "NO", conforms ? "YES" : "NO",
		selectorAvailable ? "YES" : "NO", method ? "YES" : "NO", argumentCount,
		returnCompatible ? "YES" : "NO", indexCompatible ? "YES" : "NO",
		sectionControllerCompatible ? "YES" : "NO", animatedCompatible ? "YES" : "NO");
	if (!signatureValid) {
		const char *reason = !protocolAvailable || !protocolSelectorAvailable ? "protocolUnavailable" :
			(!conforms ? "protocolConformance" :
			(!selectorAvailable ? "selectorUnavailable" :
			(!method ? "methodUnavailable" :
			(!argumentCountValid ? "argumentCount" : "signatureMismatch"))));
		MATTER_SETTINGS_LOG("Matter row deselect skipped reason=%{public}s", reason);
		return;
	}

	@try {
		((void (*)(id, SEL, NSInteger, id, BOOL))objc_msgSend)(context, selector, index,
			sectionController, YES);
		MATTER_SETTINGS_LOG("Matter row deselected");
	} @catch (__unused NSException *exception) {
		MATTER_SETTINGS_LOG("Matter row deselect skipped reason=invocationFailed");
	}
}

static void MatterSettingsEntryDidSelect(id self, SEL selector, NSInteger index) {
	(void)selector;
	if (index != 0) {
		return;
	}
	MATTER_SETTINGS_LOG("Matter row selected");
	if ([NSThread isMainThread]) {
		MatterDeselectSettingsEntry(self, index);
		MatterPushSettingsController();
	} else {
		dispatch_async(dispatch_get_main_queue(), ^{
			MatterDeselectSettingsEntry(self, index);
			MatterPushSettingsController();
		});
	}
}

static Class MatterInjectionCreateSectionControllerClass(void) {
	Class sectionBase = objc_getClass("IGListSectionController");
	const char *indexArgument[] = { @encode(NSInteger) };
	Method numberMethod = NULL;
	Method sizeMethod = NULL;
	Method cellMethod = NULL;
	Method selectMethod = NULL;
	if (!MatterInjectionBaseMethod(sectionBase, @selector(init), 2, "@", NULL, NULL) ||
	    !MatterInjectionBaseMethod(sectionBase, NSSelectorFromString(@"numberOfItems"), 2,
			@encode(NSInteger), NULL, &numberMethod) ||
	    !MatterInjectionBaseMethod(sectionBase, NSSelectorFromString(@"sizeForItemAtIndex:"), 3,
			@encode(CGSize), indexArgument, &sizeMethod) ||
	    !MatterInjectionBaseMethod(sectionBase, NSSelectorFromString(@"cellForItemAtIndex:"), 3,
			"@", indexArgument, &cellMethod) ||
	    !MatterInjectionBaseMethod(sectionBase, NSSelectorFromString(@"didSelectItemAtIndex:"), 3,
			"v", indexArgument, &selectMethod) ||
	    !MatterInjectionBaseMethod(sectionBase, NSSelectorFromString(@"collectionContext"), 2,
			"@", NULL, NULL)) {
		return Nil;
	}

	Protocol *collectionContext = objc_getProtocol("IGListCollectionContext");
	SEL containerSizeSelector = NSSelectorFromString(@"containerSize");
	SEL dequeueSelector = NSSelectorFromString(@"dequeueReusableCellOfClass:withReuseIdentifier:forSectionController:atIndex:");
	if (!collectionContext ||
	    !MatterInjectionProtocolMethodMatches(collectionContext, containerSizeSelector, "{CGSize=dd}16@0:8") ||
	    !MatterInjectionProtocolMethodMatches(collectionContext, dequeueSelector, "@48@0:8#16@24@32q40")) {
		return Nil;
	}

	Class existingClass = objc_getClass("MatterIGListSettingsSectionController");
	if (existingClass) {
		return class_getSuperclass(existingClass) == sectionBase ? existingClass : Nil;
	}

	Class sectionClass = objc_allocateClassPair(sectionBase, "MatterIGListSettingsSectionController", 0);
	if (!sectionClass ||
	    !class_addMethod(sectionClass, NSSelectorFromString(@"numberOfItems"),
			(IMP)MatterSettingsEntryNumberOfItems, method_getTypeEncoding(numberMethod)) ||
	    !class_addMethod(sectionClass, NSSelectorFromString(@"sizeForItemAtIndex:"),
			(IMP)MatterSettingsEntrySize, method_getTypeEncoding(sizeMethod)) ||
	    !class_addMethod(sectionClass, NSSelectorFromString(@"cellForItemAtIndex:"),
			(IMP)MatterSettingsEntryCellForItem, method_getTypeEncoding(cellMethod)) ||
	    !class_addMethod(sectionClass, NSSelectorFromString(@"didSelectItemAtIndex:"),
			(IMP)MatterSettingsEntryDidSelect, method_getTypeEncoding(selectMethod))) {
		if (sectionClass) {
			objc_disposeClassPair(sectionClass);
		}
		return Nil;
	}
	objc_registerClassPair(sectionClass);
	return sectionClass;
}

static BOOL MatterInjectionIsExactSettingsController(id object) {
	Class cls = object ? object_getClass(object) : Nil;
	const char *name = cls ? class_getName(cls) : NULL;
	return name && strcmp(name, "BCNSettings.BCNSettingsViewController") == 0;
}

static BOOL MatterInjectionAdapterBelongsToController(id adapter, id controller, const char **failureStep) {
	Class adapterClass = objc_getClass("IGListAdapter");
	Class runtimeClass = adapter ? object_getClass(adapter) : Nil;
	BOOL adapterAvailable = adapter != nil;
	BOOL exactClass = adapterClass && runtimeClass == adapterClass;
	MATTER_SETTINGS_LOG("contract adapter nonnil=%{public}s class=%{public}s exactIGListAdapter=%{public}s",
		adapterAvailable ? "YES" : "NO", runtimeClass ? class_getName(runtimeClass) : "(nil)",
		exactClass ? "YES" : "NO");
	if (!adapterAvailable || !controller || !exactClass) {
		if (failureStep) {
			*failureStep = "adapterIdentity";
		}
		return NO;
	}
	SEL viewControllerSelector = NSSelectorFromString(@"viewController");
	Method viewControllerMethod = class_getInstanceMethod(adapterClass, viewControllerSelector);
	BOOL selectorAvailable = [adapter respondsToSelector:viewControllerSelector];
	BOOL signatureValid = MatterInjectionMethodMatches(viewControllerMethod, 2, "@", NULL);
	MATTER_SETTINGS_LOG("contract adapter viewController selector=%{public}s signature=%{public}s",
		selectorAvailable ? "YES" : "NO", signatureValid ? "YES" : "NO");
	if (!selectorAvailable || !signatureValid) {
		if (failureStep) {
			*failureStep = "adapterViewControllerSignature";
		}
		return NO;
	}
	BOOL belongsToController = ((id (*)(id, SEL))objc_msgSend)(adapter, viewControllerSelector) == controller;
	MATTER_SETTINGS_LOG("contract adapter belongsToSettingsController=%{public}s",
		belongsToController ? "YES" : "NO");
	if (!belongsToController && failureStep) {
		*failureStep = "adapterOwnerMismatch";
	}
	return belongsToController;
}

static BOOL MatterInjectionSectionBaseIsReady(void) {
	Class sectionBase = objc_getClass("IGListSectionController");
	BOOL ready = sectionBase && MatterSettingsSectionControllerClass &&
		class_getSuperclass(MatterSettingsSectionControllerClass) == sectionBase;
	MATTER_SETTINGS_LOG("contract sectionBaseClass=%{public}s", ready ? "YES" : "NO");
	return ready;
}

static BOOL MatterInjectionSupportsFastEnumeration(id object) {
	Class collectionClass = object ? object_getClass(object) : Nil;
	Protocol *fastEnumerationProtocol = objc_getProtocol("NSFastEnumeration");
	SEL selector = @selector(countByEnumeratingWithState:objects:count:);
	Method method = collectionClass ? class_getInstanceMethod(collectionClass, selector) : NULL;
	BOOL protocolConformance = collectionClass && fastEnumerationProtocol &&
		class_conformsToProtocol(collectionClass, fastEnumerationProtocol);
	BOOL selectorAvailable = object && [object respondsToSelector:selector] && method != NULL;
	unsigned int argumentCount = method ? method_getNumberOfArguments(method) : 0;
	BOOL argumentCountValid = method && argumentCount == 5;
	char *returnType = method ? method_copyReturnType(method) : NULL;
	char *stateType = argumentCountValid ? method_copyArgumentType(method, 2) : NULL;
	char *bufferType = argumentCountValid ? method_copyArgumentType(method, 3) : NULL;
	char *countType = argumentCountValid ? method_copyArgumentType(method, 4) : NULL;
	BOOL returnCompatible = argumentCountValid &&
		MatterInjectionIsIntegerType(returnType, sizeof(NSUInteger));
	BOOL stateCompatible = argumentCountValid && MatterInjectionIsPointerType(stateType);
	BOOL bufferCompatible = argumentCountValid && MatterInjectionIsPointerType(bufferType);
	BOOL countCompatible = argumentCountValid &&
		MatterInjectionIsIntegerType(countType, sizeof(NSUInteger));
	const char *runtimeEncoding = method ? method_getTypeEncoding(method) : NULL;
	MATTER_SETTINGS_LOG("contract fastEnumerationProtocol=%{public}s",
		protocolConformance ? "YES" : "NO");
	MATTER_SETTINGS_LOG("contract fastEnumerationSelector=%{public}s", selectorAvailable ? "YES" : "NO");
	MATTER_SETTINGS_LOG("contract fastEnumerationMethod=%{public}s", method ? "YES" : "NO");
	MATTER_SETTINGS_LOG("contract fastEnumerationArgCount=%{public}u", argumentCount);
	MATTER_SETTINGS_LOG("contract fastEnumerationReturnCompatible=%{public}s", returnCompatible ? "YES" : "NO");
	MATTER_SETTINGS_LOG("contract fastEnumerationStateArgCompatible=%{public}s", stateCompatible ? "YES" : "NO");
	MATTER_SETTINGS_LOG("contract fastEnumerationBufferArgCompatible=%{public}s", bufferCompatible ? "YES" : "NO");
	MATTER_SETTINGS_LOG("contract fastEnumerationCountArgCompatible=%{public}s", countCompatible ? "YES" : "NO");
	MATTER_SETTINGS_LOG("contract fastEnumerationEncoding=%{public}s",
		runtimeEncoding ? runtimeEncoding : "(unavailable)");
	BOOL abiCompatible = argumentCountValid && returnCompatible && stateCompatible &&
		bufferCompatible && countCompatible;
	MATTER_SETTINGS_LOG("contract fastEnumerationABI=%{public}s", abiCompatible ? "YES" : "NO");
	free(returnType);
	free(stateType);
	free(bufferType);
	free(countType);
	BOOL supported = selectorAvailable && abiCompatible;
	MATTER_SETTINGS_LOG("contract fastEnumeration=%{public}s", supported ? "YES" : "NO");
	return supported;
}

static BOOL MatterInjectionSnapshotSettingsObjects(id object, NSMutableArray **snapshotOut,
		const char **failureStep) {
	BOOL objectAvailable = object != nil;
	MATTER_SETTINGS_LOG("contract object nonnil=%{public}s", objectAvailable ? "YES" : "NO");
	if (!objectAvailable) {
		if (failureStep) {
			*failureStep = "objectNil";
		}
		return NO;
	}

	Class collectionClass = object_getClass(object);
	const char *collectionClassName = collectionClass ? class_getName(collectionClass) : "(nil)";
	MATTER_SETTINGS_LOG("contract collectionClass=%{public}s", collectionClassName);
	if (!collectionClass || class_isMetaClass(collectionClass)) {
		if (failureStep) {
			*failureStep = "collectionClassUnavailable";
		}
		return NO;
	}
	if (!MatterInjectionSupportsFastEnumeration(object)) {
		if (failureStep) {
			*failureStep = "fastEnumerationUnavailable";
		}
		return NO;
	}

	NSMutableArray *snapshot = nil;
	@try {
		snapshot = [NSMutableArray arrayWithCapacity:6];
		BOOL tooManyObjects = NO;
		BOOL nilObject = NO;
		for (id element in (id<NSFastEnumeration>)object) {
			if (!element) {
				nilObject = YES;
				break;
			}
			if (snapshot.count == 6) {
				tooManyObjects = YES;
				break;
			}
			[snapshot addObject:element];
		}
		MATTER_SETTINGS_LOG("contract enumeratedCount=%{public}lu",
			(unsigned long)snapshot.count);
		if (nilObject) {
			if (failureStep) {
				*failureStep = "nilObject";
			}
			return NO;
		}
		if (tooManyObjects) {
			if (failureStep) {
				*failureStep = "tooManyObjects";
			}
			return NO;
		}
		if (snapshot.count != 6) {
			if (failureStep) {
				*failureStep = "expectedCount6";
			}
			return NO;
		}
		if (snapshotOut) {
			*snapshotOut = snapshot;
		}
		return YES;
	} @catch (__unused NSException *exception) {
		MATTER_SETTINGS_LOG("contract enumeratedCount=%{public}lu",
			(unsigned long)snapshot.count);
		if (failureStep) {
			*failureStep = "enumerationFailed";
		}
		return NO;
	}
}

static BOOL MatterInjectionHasExpectedSettingsLayout(NSArray *snapshot, const char **failureStep) {
	static const char *expectedClasses[] = {
		"IGBCNAccountsCenterViewModel",
		"IGSeparatorModel",
		"NSTaggedPointerString",
		"IGSeparatorModel",
		"IGLabelItemViewModel",
		"IGLabelItemViewModel"
	};
	if (!snapshot || snapshot.count != sizeof(expectedClasses) / sizeof(expectedClasses[0])) {
		if (failureStep) {
			*failureStep = "expectedCount6";
		}
		return NO;
	}
	for (NSUInteger index = 0; index < snapshot.count; index++) {
		id element = snapshot[index];
		Class elementClass = element ? object_getClass(element) : Nil;
		const char *elementClassName = elementClass ? class_getName(elementClass) : "(nil)";
		BOOL matches = elementClassName && strcmp(elementClassName, expectedClasses[index]) == 0;
		MATTER_SETTINGS_LOG("contract layout index=%{public}lu class=%{public}s match=%{public}s",
			(unsigned long)index, elementClassName, matches ? "YES" : "NO");
		if (!matches) {
			if (failureStep) {
				*failureStep = "layoutClass";
			}
			return NO;
		}
	}
	return YES;
}

static id MatterSettingsObjectsForListAdapterHook(id self, SEL selector, id adapter) {
	id (*original)(id, SEL, id) = (id (*)(id, SEL, id))MatterOriginalObjectsForListAdapter;
	id result = original(self, selector, adapter);
	if (!MatterInjectionIsExactSettingsController(self)) {
		return result;
	}
	MatterSettingsHostController = (UIViewController *)self;

	const char *adapterFailureStep = NULL;
	if (!MatterInjectionAdapterBelongsToController(adapter, self, &adapterFailureStep)) {
		MATTER_SETTINGS_LOG("contract FAIL step=%{public}s",
			adapterFailureStep ? adapterFailureStep : "adapterIdentity");
		MATTER_SETTINGS_LOG("settings marker skipped reason=runtimeContract step=%{public}s",
			adapterFailureStep ? adapterFailureStep : "adapterIdentity");
		return result;
	}

	NSMutableArray *snapshot = nil;
	const char *collectionFailureStep = NULL;
	BOOL sourceCollectionReady = MatterInjectionSnapshotSettingsObjects(result, &snapshot,
		&collectionFailureStep);
	const char *layoutFailureStep = NULL;
	BOOL layoutReady = sourceCollectionReady &&
		MatterInjectionHasExpectedSettingsLayout(snapshot, &layoutFailureStep);

	BOOL sectionBaseReady = MatterInjectionSectionBaseIsReady();
	const char *markerFailureStep = NULL;
	BOOL markerClassReady = MatterInjectionPrepareMarker(&markerFailureStep);
	MATTER_SETTINGS_LOG("contract marker=%{public}s", markerClassReady ? "YES" : "NO");
	BOOL ready = sourceCollectionReady && layoutReady && sectionBaseReady && markerClassReady;
	if (!ready) {
		const char *failureStep = !sectionBaseReady ? "sectionBaseClass" :
			(!markerClassReady ? markerFailureStep :
			(!sourceCollectionReady ? collectionFailureStep : layoutFailureStep));
		MATTER_SETTINGS_LOG("contract FAIL step=%{public}s", failureStep ? failureStep : "unknown");
		MATTER_SETTINGS_LOG("settings marker skipped reason=runtimeContract step=%{public}s",
			failureStep ? failureStep : "unknown");
		return result;
	}
	Protocol *diffable = objc_getProtocol("IGListDiffable");
	id marker = MatterSettingsEntryMarkerInstance();
	BOOL markerAvailable = marker && diffable && class_conformsToProtocol(object_getClass(marker), diffable);
	MATTER_SETTINGS_LOG("contract markerInstance=%{public}s", markerAvailable ? "YES" : "NO");
	if (!markerAvailable) {
		MATTER_SETTINGS_LOG("contract FAIL step=markerInstance");
		MATTER_SETTINGS_LOG("settings marker skipped reason=runtimeContract step=markerInstance");
		return result;
	}
	MATTER_SETTINGS_LOG("contract PASS");

	NSUInteger originalCount = snapshot.count;
	@try {
		[snapshot insertObject:marker atIndex:MatterSettingsEntryIndex];
		NSArray *immutableResult = [snapshot copy];
		if (!immutableResult || immutableResult.count != originalCount + 1 ||
		    [immutableResult objectAtIndex:MatterSettingsEntryIndex] != marker) {
			MATTER_SETTINGS_LOG("settings marker skipped reason=postconditionFailed");
			return result;
		}
		MATTER_SETTINGS_LOG("contract matterOwnedCopy=YES");
		MATTER_SETTINGS_LOG("settings marker inserted originalCount=%{public}lu newCount=%{public}lu",
			(unsigned long)originalCount, (unsigned long)immutableResult.count);
		return immutableResult;
	} @catch (__unused NSException *exception) {
		MATTER_SETTINGS_LOG("settings marker skipped reason=collectionException");
		return result;
	}
}

static id MatterSettingsSectionControllerForObjectHook(id self, SEL selector, id adapter, id object) {
	if (MatterInjectionIsExactSettingsController(self) &&
	    object == MatterSettingsEntryMarkerInstance() && MatterSettingsSectionControllerClass) {
		MatterSettingsHostController = (UIViewController *)self;
		id sectionController = [[MatterSettingsSectionControllerClass alloc] init];
		if (sectionController) {
			MATTER_SETTINGS_LOG("Matter section requested");
			return sectionController;
		}
		MATTER_SETTINGS_LOG("Matter section unavailable reason=initializationFailed");
	}
	id (*original)(id, SEL, id, id) = (id (*)(id, SEL, id, id))MatterOriginalSectionControllerForObject;
	return original(self, selector, adapter, object);
}

static Method MatterInjectionOwnMethod(Class cls, SEL selector) {
	unsigned int count = 0;
	Method *methods = class_copyMethodList(cls, &count);
	Method found = NULL;
	for (unsigned int index = 0; index < count; index++) {
		if (method_getName(methods[index]) == selector) {
			found = methods[index];
			break;
		}
	}
	free(methods);
	return found;
}

static BOOL MatterInjectionInstallOwnHook(Class cls, SEL selector, IMP replacement,
		const char *returnType, const char *const *argumentTypes, unsigned int argumentCount,
		IMP *originalStorage) {
	Method method = MatterInjectionOwnMethod(cls, selector);
	if (!method || !MatterInjectionMethodMatches(method, argumentCount, returnType, argumentTypes)) {
		return NO;
	}
	IMP original = method_getImplementation(method);
	if (!original || original == replacement) {
		return NO;
	}
	*originalStorage = original;
	IMP replaced = method_setImplementation(method, replacement);
	if (!replaced) {
		*originalStorage = NULL;
		return NO;
	}
	if (replaced != original) {
		*originalStorage = replaced;
	}
	return YES;
}

static BOOL MatterSettingsInjectionInstall(void) {
	Class settingsClass = objc_getClass("BCNSettings.BCNSettingsViewController");
	if (!settingsClass || !MatterInjectionPrepareMarker(NULL)) {
		return NO;
	}
	MatterSettingsSectionControllerClass = MatterInjectionCreateSectionControllerClass();
	if (!MatterSettingsSectionControllerClass) {
		return NO;
	}

	SEL objectsSelector = NSSelectorFromString(@"objectsForListAdapter:");
	SEL sectionSelector = NSSelectorFromString(@"listAdapter:sectionControllerForObject:");
	const char *objectsArguments[] = { "@" };
	const char *sectionArguments[] = { "@", "@" };
	BOOL objectsInstalled = MatterInjectionInstallOwnHook(settingsClass, objectsSelector,
		(IMP)MatterSettingsObjectsForListAdapterHook, "@", objectsArguments, 3,
		&MatterOriginalObjectsForListAdapter);
	BOOL sectionInstalled = objectsInstalled && MatterInjectionInstallOwnHook(settingsClass, sectionSelector,
		(IMP)MatterSettingsSectionControllerForObjectHook, "@", sectionArguments, 4,
		&MatterOriginalSectionControllerForObject);
	if (!sectionInstalled) {
		if (objectsInstalled) {
			Method objectsMethod = MatterInjectionOwnMethod(settingsClass, objectsSelector);
			if (objectsMethod && MatterOriginalObjectsForListAdapter) {
				method_setImplementation(objectsMethod, MatterOriginalObjectsForListAdapter);
			}
			MatterOriginalObjectsForListAdapter = NULL;
		}
		return NO;
	}
	return YES;
}

__attribute__((constructor)) static void MatterSettingsInjectionInitialize(void) {
	if (MatterSettingsInjectionInstall()) {
		MATTER_SETTINGS_LOG("settings injection enabled");
	} else {
		MATTER_SETTINGS_LOG("settings injection unavailable reason=runtimeContract");
	}
}
