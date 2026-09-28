#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>
#import <dispatch/dispatch.h>
#import <stdlib.h>
#import <string.h>
#import "MatterPreferences.h"

%config(generator=internal);

#define MATTER_UI_LOG(...) do { if (MatterDebugLoggingEnabled()) os_log(OS_LOG_DEFAULT, "[Matter:UI] " __VA_ARGS__); } while (0)

static const char *MatterUIRuntimeClassName(id object) {
	Class cls = object ? object_getClass(object) : Nil;
	const char *name = cls ? class_getName(cls) : NULL;
	return name ? name : "(nil)";
}

static BOOL MatterUIIsInstanceOfClassNamed(id object, const char *className) {
	Class baseClass = className ? objc_getClass(className) : Nil;
	if (!object || !baseClass) {
		return NO;
	}
	for (Class cls = object_getClass(object); cls; cls = class_getSuperclass(cls)) {
		if (cls == baseClass) {
			return YES;
		}
	}
	return NO;
}

static BOOL MatterUIClassNameContains(Class cls, NSString *token) {
	const char *className = cls ? class_getName(cls) : NULL;
	if (!className || !token) {
		return NO;
	}
	NSString *name = [NSString stringWithUTF8String:className];
	return name && [name rangeOfString:token options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static const char *MatterUIControllerTitleToken(id controller) {
	if (!MatterUIIsInstanceOfClassNamed(controller, "UIViewController")) {
		return "(none)";
	}
	Class cls = object_getClass(controller);
	if (!class_getInstanceMethod(cls, @selector(title))) {
		return "(none)";
	}
	NSString *title = [(UIViewController *)controller title];
	if (!title) {
		return "(none)";
	}
	return [title isKindOfClass:[NSString class]] && [title isEqualToString:@"Settings"]
		? "Settings" : "(redacted)";
}

static BOOL MatterUIControllerLooksLikeSettings(id controller) {
	if (!MatterUIIsInstanceOfClassNamed(controller, "UIViewController")) {
		return NO;
	}
	Class cls = object_getClass(controller);
	NSString *title = class_getInstanceMethod(cls, @selector(title))
		? [(UIViewController *)controller title] : nil;
	if ([title isKindOfClass:[NSString class]] && [title isEqualToString:@"Settings"]) {
		return YES;
	}
	return MatterUIClassNameContains(cls, @"setting");
}

static BOOL MatterUIClassNameHasDiffableToken(id object) {
	return object && MatterUIClassNameContains(object_getClass(object), @"Diffable");
}

static BOOL MatterUIClassIsVerifiedSettingsController(Class cls);

static __weak id MatterSettingsListAdapter = nil;
static __weak id MatterSettingsListDataSource = nil;
static Class MatterSettingsListDataSourceClass = Nil;
static IMP MatterOriginalObjectsForListAdapter = NULL;
static IMP MatterOriginalSectionControllerForObject = NULL;
static BOOL MatterObjectsForListAdapterHookInstalled = NO;
static BOOL MatterSectionControllerForObjectHookInstalled = NO;
static __weak id MatterSettingsIGDSSectionController = nil;
static IMP MatterOriginalIGDSNumberOfItems = NULL;
static IMP MatterOriginalIGDSCellForItemAtIndex = NULL;
static IMP MatterOriginalIGDSDidSelectItemAtIndex = NULL;
static IMP MatterOriginalIGDSViewModelsForObject = NULL;
static IMP MatterOriginalIGDSCellForViewModelAtIndex = NULL;
static IMP MatterOriginalIGDSDidSelectViewModelAtIndex = NULL;
static BOOL MatterIGDSNumberOfItemsHookInstalled = NO;
static BOOL MatterIGDSCellForItemHookInstalled = NO;
static BOOL MatterIGDSDidSelectItemHookInstalled = NO;
static BOOL MatterIGDSViewModelsForObjectHookInstalled = NO;
static BOOL MatterIGDSCellForViewModelHookInstalled = NO;
static BOOL MatterIGDSDidSelectViewModelHookInstalled = NO;
static BOOL MatterInspectedNativeRowViewModel = NO;
static void MatterUIInspectIGDSSectionController(id sectionController);

static BOOL MatterUIMethodHasObjectSignature(Method method, unsigned int expectedArgumentCount) {
	if (!method || method_getNumberOfArguments(method) != expectedArgumentCount) {
		return NO;
	}

	char *returnType = method_copyReturnType(method);
	BOOL valid = returnType && returnType[0] == '@';
	free(returnType);
	for (unsigned int index = 2; valid && index < expectedArgumentCount; index++) {
		char *argumentType = method_copyArgumentType(method, index);
		valid = argumentType && argumentType[0] == '@';
		free(argumentType);
	}
	return valid;
}

static id MatterUIReadObjectSelector(id object, SEL selector) {
	if (!object || !selector || ![object respondsToSelector:selector]) {
		return nil;
	}
	Method method = class_getInstanceMethod(object_getClass(object), selector);
	if (!MatterUIMethodHasObjectSignature(method, 2)) {
		return nil;
	}
	return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static void MatterUIInspectSettingsObjects(id result) {
	if (!result) {
		MATTER_UI_LOG("objects result=nil");
		return;
	}
	if (!MatterUIIsInstanceOfClassNamed(result, "NSArray")) {
		MATTER_UI_LOG("objects resultClass=%{public}s count=unavailable reason=notNSArray",
			MatterUIRuntimeClassName(result));
		return;
	}

	@try {
		NSArray *objects = (NSArray *)result;
		NSUInteger count = objects.count;
		MATTER_UI_LOG("objects resultClass=%{public}s count=%{public}lu",
			MatterUIRuntimeClassName(result), (unsigned long)count);
		NSUInteger limit = MIN(count, (NSUInteger)30);
		for (NSUInteger index = 0; index < limit; index++) {
			id object = [objects objectAtIndex:index];
			MATTER_UI_LOG("settings object[%{public}lu] class=%{public}s",
				(unsigned long)index, MatterUIRuntimeClassName(object));
		}
		if (count > limit) {
			MATTER_UI_LOG("objects truncated max=30");
		}
	} @catch (__unused NSException *exception) {
		MATTER_UI_LOG("objects inspection unavailable reason=collectionException");
	}
}

typedef id (*MatterObjectsForListAdapterIMP)(id, SEL, id);
typedef id (*MatterSectionControllerForObjectIMP)(id, SEL, id, id);

static id MatterSettingsObjectsForListAdapterHook(id self, SEL selector, id adapter) {
	MatterObjectsForListAdapterIMP original = (MatterObjectsForListAdapterIMP)MatterOriginalObjectsForListAdapter;
	id result = original(self, selector, adapter);
	if (adapter && adapter == MatterSettingsListAdapter && self == MatterSettingsListDataSource) {
		MatterUIInspectSettingsObjects(result);
	}
	return result;
}

static id MatterSettingsSectionControllerForObjectHook(id self, SEL selector, id adapter, id object) {
	MatterSectionControllerForObjectIMP original = (MatterSectionControllerForObjectIMP)MatterOriginalSectionControllerForObject;
	id sectionController = original(self, selector, adapter, object);
	if (adapter && adapter == MatterSettingsListAdapter && self == MatterSettingsListDataSource) {
		MATTER_UI_LOG("section objectClass=%{public}s sectionControllerClass=%{public}s nil=%{public}s",
			MatterUIRuntimeClassName(object), MatterUIRuntimeClassName(sectionController),
			sectionController ? "NO" : "YES");
		if (MatterDebugLoggingEnabled() && sectionController &&
		    strcmp(MatterUIRuntimeClassName(object), "NSTaggedPointerString") == 0 &&
		    strcmp(MatterUIRuntimeClassName(sectionController), "IGDSListSectionController") == 0) {
			if (!MatterSettingsIGDSSectionController) {
				MatterSettingsIGDSSectionController = sectionController;
				MATTER_UI_LOG("settings IGDS section captured class=%{public}s",
					MatterUIRuntimeClassName(sectionController));
				MatterUIInspectIGDSSectionController(sectionController);
			} else if (MatterSettingsIGDSSectionController != sectionController) {
				MATTER_UI_LOG("additional matching IGDS settings section ignored");
			}
		}
	}
	return sectionController;
}

static Method MatterUIOwnMethod(Class cls, SEL selector);

static BOOL MatterUIInstallObjectHook(Class cls, SEL selector, IMP replacement, IMP *originalStorage,
		BOOL *installedStorage, unsigned int expectedArgumentCount) {
	if (!cls || !selector || !replacement || !originalStorage || !installedStorage) {
		return NO;
	}
	if (*installedStorage) {
		return YES;
	}
	Method method = class_getInstanceMethod(cls, selector);
	if (!MatterUIMethodHasObjectSignature(method, expectedArgumentCount)) {
		return NO;
	}
	const char *typeEncoding = method_getTypeEncoding(method);
	if (!typeEncoding) {
		return NO;
	}

	Method ownMethod = MatterUIOwnMethod(cls, selector);
	if (ownMethod) {
		IMP original = method_getImplementation(ownMethod);
		if (!original || original == replacement) {
			return NO;
		}
		*originalStorage = original;
		IMP replacedImplementation = method_setImplementation(ownMethod, replacement);
		if (!replacedImplementation) {
			*originalStorage = NULL;
			return NO;
		}
		if (replacedImplementation != replacement) {
			*originalStorage = replacedImplementation;
		}
	} else {
		IMP original = method_getImplementation(method);
		if (!original || original == replacement) {
			return NO;
		}
		*originalStorage = original;
		if (!class_addMethod(cls, selector, replacement, typeEncoding)) {
			*originalStorage = NULL;
			return NO;
		}
	}
	*installedStorage = YES;
	return YES;
}

static void MatterUIInspectSettingsAdapter(id adapter) {
	if (!adapter) {
		MATTER_UI_LOG("adapter unavailable reason=nil");
		return;
	}

	SEL dataSourceSelector = NSSelectorFromString(@"dataSource");
	SEL viewControllerSelector = NSSelectorFromString(@"viewController");
	BOOL hasDataSource = [adapter respondsToSelector:dataSourceSelector] &&
		MatterUIMethodHasObjectSignature(class_getInstanceMethod(object_getClass(adapter), dataSourceSelector), 2);
	BOOL hasViewController = [adapter respondsToSelector:viewControllerSelector] &&
		MatterUIMethodHasObjectSignature(class_getInstanceMethod(object_getClass(adapter), viewControllerSelector), 2);
	id dataSource = hasDataSource ? MatterUIReadObjectSelector(adapter, dataSourceSelector) : nil;
	id viewController = hasViewController ? MatterUIReadObjectSelector(adapter, viewControllerSelector) : nil;
	MatterSettingsListAdapter = adapter;

	MATTER_UI_LOG("adapter class=%{public}s dataSource=%{public}s viewController=%{public}s",
		MatterUIRuntimeClassName(adapter), MatterUIRuntimeClassName(dataSource),
		MatterUIRuntimeClassName(viewController));
	if (!hasDataSource || !dataSource) {
		MATTER_UI_LOG("adapter dataSource unavailable reason=%{public}s",
			hasDataSource ? "nil" : "selectorOrSignatureUnavailable");
		return;
	}
	if (MatterSettingsListDataSourceClass && MatterSettingsListDataSourceClass != object_getClass(dataSource)) {
		MATTER_UI_LOG("adapter instrumentation unavailable reason=dataSourceClassChanged");
		return;
	}

	MatterSettingsListDataSource = dataSource;
	Class dataSourceClass = object_getClass(dataSource);
	SEL objectsSelector = NSSelectorFromString(@"objectsForListAdapter:");
	SEL sectionSelector = NSSelectorFromString(@"listAdapter:sectionControllerForObject:");
	SEL emptyViewSelector = NSSelectorFromString(@"emptyViewForListAdapter:");
	BOOL hasObjects = [dataSource respondsToSelector:objectsSelector];
	BOOL hasSections = [dataSource respondsToSelector:sectionSelector];
	BOOL hasEmptyView = [dataSource respondsToSelector:emptyViewSelector];
	MATTER_UI_LOG("adapter dataSourceClass=%{public}s objectsForListAdapter=%{public}s sectionControllerForObject=%{public}s emptyViewForListAdapter=%{public}s",
		class_getName(dataSourceClass), hasObjects ? "YES" : "NO", hasSections ? "YES" : "NO",
		hasEmptyView ? "YES" : "NO");

	if (hasObjects && !MatterObjectsForListAdapterHookInstalled) {
		if (MatterUIInstallObjectHook(dataSourceClass, objectsSelector,
				(IMP)MatterSettingsObjectsForListAdapterHook, &MatterOriginalObjectsForListAdapter,
				&MatterObjectsForListAdapterHookInstalled, 3)) {
			MatterSettingsListDataSourceClass = dataSourceClass;
			MATTER_UI_LOG("adapter hook installed selector=objectsForListAdapter:");
		} else {
			MATTER_UI_LOG("adapter hook unavailable selector=objectsForListAdapter: reason=signatureOrInstallFailed");
		}
	}
	if (hasSections && !MatterSectionControllerForObjectHookInstalled) {
		if (MatterUIInstallObjectHook(dataSourceClass, sectionSelector,
				(IMP)MatterSettingsSectionControllerForObjectHook, &MatterOriginalSectionControllerForObject,
				&MatterSectionControllerForObjectHookInstalled, 4)) {
			MatterSettingsListDataSourceClass = dataSourceClass;
			MATTER_UI_LOG("adapter hook installed selector=listAdapter:sectionControllerForObject:");
		} else {
			MATTER_UI_LOG("adapter hook unavailable selector=listAdapter:sectionControllerForObject: reason=signatureOrInstallFailed");
		}
	}
}

static BOOL MatterUIInspectView(UIView *view, NSUInteger depth, NSUInteger *loggedCount, id controller) {
	if (!view || !loggedCount || *loggedCount >= 30 || depth > 2) {
		return NO;
	}

	Class viewClass = object_getClass(view);
	const char *className = MatterUIRuntimeClassName(view);
	BOOL foundList = NO;
	MATTER_UI_LOG("view depth=%{public}lu class=%{public}s", (unsigned long)depth, className);
	(*loggedCount)++;

	if (MatterUIClassNameContains(viewClass, @"_UIHostingView")) {
		MATTER_UI_LOG("hostingView class=%{public}s", className);
	}
	if (MatterUIClassNameHasDiffableToken(view)) {
		MATTER_UI_LOG("diffableRelated class=%{public}s", className);
	}

	if (MatterUIIsInstanceOfClassNamed(view, "UITableView")) {
		foundList = YES;
		UITableView *table = (UITableView *)view;
		id dataSource = table.dataSource;
		id delegate = table.delegate;
		MATTER_UI_LOG("table class=%{public}s dataSource=%{public}s delegate=%{public}s diffableDataSource=%{public}s",
			className, MatterUIRuntimeClassName(dataSource), MatterUIRuntimeClassName(delegate),
			MatterUIClassNameHasDiffableToken(dataSource) ? "YES" : "NO");
	} else if (MatterUIIsInstanceOfClassNamed(view, "UICollectionView")) {
		foundList = YES;
		UICollectionView *collection = (UICollectionView *)view;
		id dataSource = collection.dataSource;
		id delegate = collection.delegate;
		MATTER_UI_LOG("collection class=%{public}s dataSource=%{public}s delegate=%{public}s diffableDataSource=%{public}s",
			className, MatterUIRuntimeClassName(dataSource), MatterUIRuntimeClassName(delegate),
			MatterUIClassNameHasDiffableToken(dataSource) ? "YES" : "NO");
		if (MatterUIClassIsVerifiedSettingsController(object_getClass(controller))) {
			MatterUIInspectSettingsAdapter(dataSource);
		}
	} else if (MatterUIIsInstanceOfClassNamed(view, "UIScrollView")) {
		MATTER_UI_LOG("scrollView class=%{public}s", className);
	}

	if (depth >= 2 || *loggedCount >= 30) {
		return foundList;
	}
	for (UIView *subview in view.subviews) {
		if (*loggedCount >= 30) {
			MATTER_UI_LOG("view hierarchy truncated maxViews=30");
			return foundList;
		}
		if (MatterUIIsInstanceOfClassNamed(subview, "UIView")) {
			foundList = MatterUIInspectView(subview, depth + 1, loggedCount, controller) || foundList;
		}
	}
	return foundList;
}

static BOOL MatterUIInspectSettingsController(id controller) {
	if (!MatterDebugLoggingEnabled()) {
		return NO;
	}
	if (!MatterUIControllerLooksLikeSettings(controller)) {
		return NO;
	}

	Class controllerClass = object_getClass(controller);
	if (MatterUIClassNameContains(controllerClass, @"UIHostingController")) {
		MATTER_UI_LOG("hostingController class=%{public}s", MatterUIRuntimeClassName(controller));
	}
	if (!class_getInstanceMethod(controllerClass, @selector(viewIfLoaded))) {
		MATTER_UI_LOG("settings hierarchy unavailable reason=viewIfLoadedMissing");
		return NO;
	}
	UIView *rootView = [(UIViewController *)controller viewIfLoaded];
	if (!rootView) {
		MATTER_UI_LOG("settings hierarchy unavailable reason=viewNotLoaded");
		return NO;
	}
	if (!MatterUIIsInstanceOfClassNamed(rootView, "UIView")) {
		MATTER_UI_LOG("settings hierarchy unavailable reason=unknownViewClass");
		return NO;
	}

	NSUInteger loggedCount = 0;
	return MatterUIInspectView(rootView, 0, &loggedCount, controller);
}

static void MatterUIInspectSettingsAppearance(UIViewController *controller) {
	if (!MatterDebugLoggingEnabled()) {
		return;
	}
	MATTER_UI_LOG("settings appeared class=%{public}s", MatterUIRuntimeClassName(controller));
	if (MatterUIInspectSettingsController(controller)) {
		return;
	}

	static BOOL recheckScheduled = NO;
	if (recheckScheduled) {
		MATTER_UI_LOG("settings list unavailable; one recheck already used");
		return;
	}
	recheckScheduled = YES;
	MATTER_UI_LOG("settings list unavailable; scheduling one recheck delayMs=250");
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
		MATTER_UI_LOG("settings recheck class=%{public}s", MatterUIRuntimeClassName(controller));
		BOOL foundList = MatterUIInspectSettingsController(controller);
		MATTER_UI_LOG("settings recheck complete listFound=%{public}s", foundList ? "YES" : "NO");
	});
}

typedef void (*MatterViewDidAppearIMP)(id, SEL, BOOL);
static MatterViewDidAppearIMP MatterOriginalSettingsViewDidAppear = NULL;
typedef void (*MatterViewDidLoadIMP)(id, SEL);
static MatterViewDidLoadIMP MatterOriginalSettingsViewDidLoad = NULL;

static BOOL MatterUIClassIsVerifiedSettingsController(Class cls) {
	const char *name = cls ? class_getName(cls) : NULL;
	return name && strcmp(name, "BCNSettings.BCNSettingsViewController") == 0;
}

static Method MatterUIOwnMethod(Class cls, SEL selector) {
	unsigned int methodCount = 0;
	Method *methods = cls ? class_copyMethodList(cls, &methodCount) : NULL;
	Method found = NULL;
	for (unsigned int index = 0; index < methodCount; index++) {
		if (method_getName(methods[index]) == selector) {
			found = methods[index];
			break;
		}
	}
	free(methods);
	return found;
}

static BOOL MatterUIMethodHasSimpleSignature(Method method, unsigned int argumentCount,
		char returnCode, char explicitArgumentCode) {
	if (!method || method_getNumberOfArguments(method) != argumentCount) {
		return NO;
	}
	char *returnType = method_copyReturnType(method);
	BOOL valid = returnType && returnType[0] == returnCode;
	free(returnType);
	if (valid && explicitArgumentCode) {
		char *argumentType = method_copyArgumentType(method, 2);
		valid = argumentType && argumentType[0] == explicitArgumentCode;
		free(argumentType);
	}
	return valid;
}

static BOOL MatterUIMethodHasSignatureCodes(Method method, unsigned int argumentCount,
		char returnCode, const char *explicitArgumentCodes) {
	if (!method || method_getNumberOfArguments(method) != argumentCount) {
		return NO;
	}
	char *actualReturnCode = method_copyReturnType(method);
	BOOL valid = actualReturnCode && actualReturnCode[0] == returnCode;
	free(actualReturnCode);
	for (unsigned int index = 2; valid && index < argumentCount; index++) {
		char *actualArgumentCode = method_copyArgumentType(method, index);
		valid = actualArgumentCode && actualArgumentCode[0] == explicitArgumentCodes[index - 2];
		free(actualArgumentCode);
	}
	return valid;
}

static BOOL MatterUIInstallScopedIGDSHook(Class cls, SEL selector, IMP replacement,
		IMP *originalStorage, BOOL *installedStorage) {
	if (!cls || !selector || !replacement || !originalStorage || !installedStorage ||
	    !MatterSettingsIGDSSectionController ||
	    object_getClass(MatterSettingsIGDSSectionController) != cls ||
	    strcmp(class_getName(cls), "IGDSListSectionController") != 0) {
		return NO;
	}
	if (*installedStorage) {
		return YES;
	}
	Method method = class_getInstanceMethod(cls, selector);
	const char *typeEncoding = method ? method_getTypeEncoding(method) : NULL;
	if (!typeEncoding) {
		return NO;
	}
	Method ownMethod = MatterUIOwnMethod(cls, selector);
	if (ownMethod) {
		IMP original = method_getImplementation(ownMethod);
		if (!original || original == replacement) {
			return NO;
		}
		*originalStorage = original;
		IMP replaced = method_setImplementation(ownMethod, replacement);
		if (!replaced) {
			*originalStorage = NULL;
			return NO;
		}
		if (replaced != replacement) {
			*originalStorage = replaced;
		}
	} else {
		IMP original = method_getImplementation(method);
		if (!original || original == replacement) {
			return NO;
		}
		*originalStorage = original;
		if (!class_addMethod(cls, selector, replacement, typeEncoding)) {
			*originalStorage = NULL;
			return NO;
		}
	}
	*installedStorage = YES;
	return YES;
}

typedef NSInteger (*MatterIGDSNumberOfItemsIMP)(id, SEL);
typedef id (*MatterIGDSCellForItemAtIndexIMP)(id, SEL, NSInteger);
typedef void (*MatterIGDSDidSelectItemAtIndexIMP)(id, SEL, NSInteger);

static NSInteger MatterIGDSNumberOfItemsHook(id self, SEL selector) {
	MatterIGDSNumberOfItemsIMP original = (MatterIGDSNumberOfItemsIMP)MatterOriginalIGDSNumberOfItems;
	NSInteger count = original(self, selector);
	if (self == MatterSettingsIGDSSectionController) {
		MATTER_UI_LOG("IGDS settings numberOfItems=%{public}lld", (long long)count);
	}
	return count;
}

static id MatterIGDSCellForItemAtIndexHook(id self, SEL selector, NSInteger index) {
	MatterIGDSCellForItemAtIndexIMP original = (MatterIGDSCellForItemAtIndexIMP)MatterOriginalIGDSCellForItemAtIndex;
	id cell = original(self, selector, index);
	if (self == MatterSettingsIGDSSectionController) {
		MATTER_UI_LOG("IGDS settings cell index=%{public}lld class=%{public}s nil=%{public}s",
			(long long)index, MatterUIRuntimeClassName(cell), cell ? "NO" : "YES");
	}
	return cell;
}

static void MatterIGDSDidSelectItemAtIndexHook(id self, SEL selector, NSInteger index) {
	MatterIGDSDidSelectItemAtIndexIMP original = (MatterIGDSDidSelectItemAtIndexIMP)MatterOriginalIGDSDidSelectItemAtIndex;
	original(self, selector, index);
	if (self == MatterSettingsIGDSSectionController) {
		MATTER_UI_LOG("IGDS settings selected index=%{public}lld", (long long)index);
	}
}

typedef id (*MatterIGDSViewModelsForObjectIMP)(id, SEL, id, id);
typedef id (*MatterIGDSCellForViewModelAtIndexIMP)(id, SEL, id, id, NSInteger);
typedef void (*MatterIGDSDidSelectViewModelAtIndexIMP)(id, SEL, id, NSInteger, id);

static BOOL MatterUISelectorMatchesTokens(const char *name, NSArray<NSString *> *tokens) {
	if (!name) {
		return NO;
	}
	NSString *selectorName = [[NSString stringWithUTF8String:name] lowercaseString];
	for (NSString *token in tokens) {
		if ([selectorName rangeOfString:token].location != NSNotFound) {
			return YES;
		}
	}
	return NO;
}

static void MatterUIInspectModelMethods(Class cls, NSArray<NSString *> *tokens,
		NSUInteger maximum, const char *logPrefix, BOOL reportConstructors) {
	if (!cls || !tokens || !logPrefix || maximum == 0) {
		return;
	}
	const char *className = class_getName(cls);
	NSUInteger logged = 0;
	Class owners[] = { cls, object_getClass(cls) };
	const char *ownerKinds[] = { "instance", "class" };
	for (NSUInteger ownerIndex = 0; ownerIndex < 2 && logged < maximum; ownerIndex++) {
		unsigned int methodCount = 0;
		Method *methods = class_copyMethodList(owners[ownerIndex], &methodCount);
		for (unsigned int methodIndex = 0; methodIndex < methodCount && logged < maximum; methodIndex++) {
			const char *selectorName = sel_getName(method_getName(methods[methodIndex]));
			if (MatterUISelectorMatchesTokens(selectorName, tokens)) {
				MATTER_UI_LOG("%{public}s method class=%{public}s kind=%{public}s selector=%{public}s",
					logPrefix, className ? className : "(unknown)", ownerKinds[ownerIndex], selectorName);
				NSString *lowerName = [[NSString stringWithUTF8String:selectorName] lowercaseString];
				BOOL modelLike = [lowerName containsString:@"model"] ||
					[lowerName containsString:@"textviewmodel"];
				BOOL textFactoryLike = [lowerName containsString:@"text"] &&
					([lowerName containsString:@"with"] || [lowerName containsString:@"for"]);
				BOOL plausibleConstructor = [lowerName hasPrefix:@"init"] ||
					[lowerName containsString:@"factory"] || [lowerName containsString:@"create"] ||
					[lowerName containsString:@"make"] ||
					(modelLike && ([lowerName containsString:@"with"] || [lowerName containsString:@"for"])) ||
					textFactoryLike;
				if (reportConstructors && plausibleConstructor) {
					const char *encoding = method_getTypeEncoding(methods[methodIndex]);
					MATTER_UI_LOG("textVM constructor selector=%{public}s encoding=%{public}s kind=%{public}s",
						selectorName, encoding ? encoding : "(unavailable)", ownerKinds[ownerIndex]);
				}
				logged++;
			}
		}
		free(methods);
	}
	if (logged == 0) {
		MATTER_UI_LOG("%{public}s method list class=%{public}s noMatchingSelectors",
			logPrefix, className ? className : "(unknown)");
	} else if (logged == maximum) {
		MATTER_UI_LOG("%{public}s method list class=%{public}s truncated max=%{public}lu",
			logPrefix, className ? className : "(unknown)", (unsigned long)maximum);
	}
}

static id MatterUIReadNativeRowObjectGetter(id rowViewModel, const char *getterName) {
	SEL selector = NSSelectorFromString([NSString stringWithUTF8String:getterName]);
	if (![rowViewModel respondsToSelector:selector]) {
		MATTER_UI_LOG("native row getter=%{public}s available=NO", getterName);
		return nil;
	}
	Method method = class_getInstanceMethod(object_getClass(rowViewModel), selector);
	if (!MatterUIMethodHasObjectSignature(method, 2)) {
		MATTER_UI_LOG("native row getter=%{public}s available=YES readable=NO reason=signature", getterName);
		return nil;
	}
	@try {
		id value = ((id (*)(id, SEL))objc_msgSend)(rowViewModel, selector);
		MATTER_UI_LOG("native row %{public}s class=%{public}s nil=%{public}s",
			getterName, MatterUIRuntimeClassName(value), value ? "NO" : "YES");
		return value;
	} @catch (__unused NSException *exception) {
		MATTER_UI_LOG("native row getter=%{public}s readable=NO reason=exception", getterName);
		return nil;
	}
}

static void MatterUIInspectNativeRowBoolGetter(id rowViewModel, const char *getterName) {
	SEL selector = NSSelectorFromString([NSString stringWithUTF8String:getterName]);
	if (![rowViewModel respondsToSelector:selector]) {
		MATTER_UI_LOG("native row getter=%{public}s available=NO", getterName);
		return;
	}
	Method method = class_getInstanceMethod(object_getClass(rowViewModel), selector);
	char *returnType = method ? method_copyReturnType(method) : NULL;
	BOOL valid = method && method_getNumberOfArguments(method) == 2 && returnType &&
		(returnType[0] == 'c' || returnType[0] == 'B');
	free(returnType);
	if (!valid) {
		MATTER_UI_LOG("native row getter=%{public}s available=YES readable=NO reason=signature", getterName);
		return;
	}
	@try {
		BOOL value = ((BOOL (*)(id, SEL))objc_msgSend)(rowViewModel, selector);
		MATTER_UI_LOG("native row %{public}s=%{public}s", getterName, value ? "YES" : "NO");
	} @catch (__unused NSException *exception) {
		MATTER_UI_LOG("native row getter=%{public}s readable=NO reason=exception", getterName);
	}
}

static const char *MatterUITypeKind(char typeCode) {
	switch (typeCode) {
		case '@': return "object";
		case 'B': return "booleanScalar";
		case 'c': case 'C': case 's': case 'S': case 'i': case 'I': case 'l': case 'L': case 'q': case 'Q':
			return "integerScalar";
		case 'f': case 'd': return "floatingScalar";
		case '#': return "class";
		case ':': return "selector";
		case '^': return "pointer";
		case '{': return "struct";
		default: return "unsupported";
	}
}

static void MatterUIInspectNativeRowTag(id rowViewModel) {
	SEL selector = NSSelectorFromString(@"tag");
	if (![rowViewModel respondsToSelector:selector]) {
		MATTER_UI_LOG("IGDS tag selector=NO");
		return;
	}
	Method method = class_getInstanceMethod(object_getClass(rowViewModel), selector);
	char *returnType = method ? method_copyReturnType(method) : NULL;
	if (!method || method_getNumberOfArguments(method) != 2 || !returnType) {
		MATTER_UI_LOG("IGDS tag selector=YES encoding=unavailable kind=unsupported");
		free(returnType);
		return;
	}
	char typeCode = returnType[0];
	MATTER_UI_LOG("IGDS tag selector=YES encoding=%{public}s kind=%{public}s",
		returnType, MatterUITypeKind(typeCode));
	free(returnType);
}

static void MatterUIInspectNativeRowViewModel(id rowViewModel) {
	Class cls = object_getClass(rowViewModel);
	SEL modelInitializer = NSSelectorFromString(
		@"initWithTextViewModel:icon:iconTintColor:addOnViewModel:checked:disabled:tag:");
	Method initializerMethod = class_getInstanceMethod(cls, modelInitializer);
	if (initializerMethod) {
		const char *encoding = method_getTypeEncoding(initializerMethod);
		MATTER_UI_LOG("native row initializer selector=initWithTextViewModel:icon:iconTintColor:addOnViewModel:checked:disabled:tag: encoding=%{public}s kind=instance",
			encoding ? encoding : "(unavailable)");
	}

	id textViewModel = MatterUIReadNativeRowObjectGetter(rowViewModel, "textViewModel");
	id icon = MatterUIReadNativeRowObjectGetter(rowViewModel, "icon");
	(void)MatterUIReadNativeRowObjectGetter(rowViewModel, "iconTintColor");
	id addOnViewModel = MatterUIReadNativeRowObjectGetter(rowViewModel, "addOnViewModel");
	MatterUIInspectNativeRowBoolGetter(rowViewModel, "checked");
	MatterUIInspectNativeRowBoolGetter(rowViewModel, "disabled");
	MatterUIInspectNativeRowTag(rowViewModel);

	if (textViewModel) {
		Class textClass = object_getClass(textViewModel);
		MATTER_UI_LOG("textViewModel runtimeClass=%{public}s", MatterUIRuntimeClassName(textViewModel));
		MatterUIInspectModelMethods(textClass,
			@[@"init", @"text", @"title", @"primary", @"secondary", @"attributed", @"style",
			  @"color", @"font", @"alignment", @"numberoflines", @"line", @"label", @"factory",
			  @"create", @"make", @"model"],
			60, "textVM", YES);
	} else {
		MATTER_UI_LOG("textViewModel runtimeClass=(nil)");
	}

	if (addOnViewModel) {
		MATTER_UI_LOG("native row addOnViewModel runtimeClass=%{public}s", MatterUIRuntimeClassName(addOnViewModel));
		MatterUIInspectModelMethods(object_getClass(addOnViewModel),
			@[@"chevron", @"disclosure", @"icon", @"accessory", @"image", @"type", @"style", @"init", @"model"],
			40, "addOn", NO);
	}
	if (icon) {
		MatterUIInspectModelMethods(object_getClass(icon),
			@[@"image", @"icon", @"name", @"symbol", @"init", @"model"], 30, "icon", NO);
	}
}

static void MatterUIInspectViewModelCollection(id result) {
	if (!result) {
		MATTER_UI_LOG("IGDS viewModels resultClass=%{public}s nil=YES", MatterUIRuntimeClassName(result));
		return;
	}
	if (!MatterUIIsInstanceOfClassNamed(result, "NSArray")) {
		MATTER_UI_LOG("IGDS viewModels resultClass=%{public}s nil=NO count=unavailable reason=notNSArray",
			MatterUIRuntimeClassName(result));
		return;
	}

	@try {
		NSArray *viewModels = (NSArray *)result;
		NSUInteger totalCount = viewModels.count;
		NSUInteger limit = MIN(totalCount, (NSUInteger)30);
		Class classes[30] = { Nil };
		NSUInteger classCounts[30] = { 0 };
		NSUInteger uniqueClassCount = 0;
		MATTER_UI_LOG("IGDS viewModels resultClass=%{public}s nil=NO count=%{public}lu",
			MatterUIRuntimeClassName(result), (unsigned long)totalCount);
		for (NSUInteger index = 0; index < limit; index++) {
			id viewModel = [viewModels objectAtIndex:index];
			Class viewModelClass = viewModel ? object_getClass(viewModel) : Nil;
			const char *viewModelClassName = viewModelClass ? class_getName(viewModelClass) : "(nil)";
			MATTER_UI_LOG("IGDS viewModel[%{public}lu] class=%{public}s",
				(unsigned long)index, viewModelClassName);
			NSUInteger classIndex = 0;
			for (; classIndex < uniqueClassCount; classIndex++) {
				if (classes[classIndex] == viewModelClass) {
					break;
				}
			}
			if (classIndex == uniqueClassCount) {
				classes[uniqueClassCount] = viewModelClass;
				classCounts[uniqueClassCount] = 0;
				uniqueClassCount++;
			}
			classCounts[classIndex]++;
			if (viewModelClass && !MatterInspectedNativeRowViewModel &&
			    strcmp(class_getName(viewModelClass), "IGDSListCellViewModel") == 0) {
				MatterInspectedNativeRowViewModel = YES;
				MatterUIInspectNativeRowViewModel(viewModel);
			}
		}
		MATTER_UI_LOG("IGDS viewModel summary total=%{public}lu inspected=%{public}lu uniqueClasses=%{public}lu",
			(unsigned long)totalCount, (unsigned long)limit, (unsigned long)uniqueClassCount);
		for (NSUInteger index = 0; index < uniqueClassCount; index++) {
			const char *name = classes[index] ? class_getName(classes[index]) : "(nil)";
			MATTER_UI_LOG("IGDS viewModel class=%{public}s count=%{public}lu",
				name, (unsigned long)classCounts[index]);
		}
		if (totalCount > limit) {
			MATTER_UI_LOG("IGDS viewModels truncated max=30");
		}
	} @catch (__unused NSException *exception) {
		MATTER_UI_LOG("IGDS viewModels inspection unavailable reason=collectionException");
	}
}

static id MatterIGDSViewModelsForObjectHook(id self, SEL selector, id sectionController, id object) {
	MatterIGDSViewModelsForObjectIMP original =
		(MatterIGDSViewModelsForObjectIMP)MatterOriginalIGDSViewModelsForObject;
	id result = original(self, selector, sectionController, object);
	if (self == MatterSettingsIGDSSectionController) {
		MatterUIInspectViewModelCollection(result);
	}
	return result;
}

static id MatterIGDSCellForViewModelAtIndexHook(id self, SEL selector, id sectionController,
		id viewModel, NSInteger index) {
	MatterIGDSCellForViewModelAtIndexIMP original =
		(MatterIGDSCellForViewModelAtIndexIMP)MatterOriginalIGDSCellForViewModelAtIndex;
	id cell = original(self, selector, sectionController, viewModel, index);
	if (self == MatterSettingsIGDSSectionController) {
		MATTER_UI_LOG("IGDS cellVM index=%{public}lld viewModelClass=%{public}s cellClass=%{public}s nil=%{public}s",
			(long long)index, MatterUIRuntimeClassName(viewModel), MatterUIRuntimeClassName(cell),
			cell ? "NO" : "YES");
	}
	return cell;
}

static void MatterIGDSDidSelectViewModelAtIndexHook(id self, SEL selector, id sectionController,
		NSInteger index, id viewModel) {
	MatterIGDSDidSelectViewModelAtIndexIMP original =
		(MatterIGDSDidSelectViewModelAtIndexIMP)MatterOriginalIGDSDidSelectViewModelAtIndex;
	original(self, selector, sectionController, index, viewModel);
	if (self == MatterSettingsIGDSSectionController) {
		MATTER_UI_LOG("IGDS selectedVM index=%{public}lld viewModelClass=%{public}s",
			(long long)index, MatterUIRuntimeClassName(viewModel));
	}
}

static BOOL MatterUISelectorNameMatches(const char *name) {
	if (!name) {
		return NO;
	}
	NSString *selectorName = [[NSString stringWithUTF8String:name] lowercaseString];
	for (NSString *token in @[@"item", @"model", @"row", @"cell", @"section", @"data", @"select", @"view"]) {
		if ([selectorName rangeOfString:token].location != NSNotFound) {
			return YES;
		}
	}
	return NO;
}

static void MatterUIInspectIGDSMethodNames(Class cls) {
	NSUInteger logged = 0;
	NSUInteger depth = 0;
	for (Class current = cls; current && depth < 4 && logged < 50; current = class_getSuperclass(current), depth++) {
		unsigned int methodCount = 0;
		Method *methods = class_copyMethodList(current, &methodCount);
		for (unsigned int index = 0; index < methodCount && logged < 50; index++) {
			const char *name = sel_getName(method_getName(methods[index]));
			if (MatterUISelectorNameMatches(name)) {
				MATTER_UI_LOG("IGDS method ownerClass=%{public}s selector=%{public}s", class_getName(current), name);
				logged++;
			}
		}
		free(methods);
	}
	if (logged == 0) {
		MATTER_UI_LOG("IGDS method list no matching selectors");
	} else if (logged == 50) {
		MATTER_UI_LOG("IGDS method list truncated max=50");
	}
}

static void MatterUIInspectIGDSProviderResult(const char *selectorName, id result) {
	if (!result) {
		MATTER_UI_LOG("IGDS %{public}s result=nil", selectorName);
		return;
	}
	if (!MatterUIIsInstanceOfClassNamed(result, "NSArray")) {
		MATTER_UI_LOG("IGDS %{public}s class=%{public}s count=unavailable",
			selectorName, MatterUIRuntimeClassName(result));
		return;
	}

	@try {
		NSArray *items = (NSArray *)result;
		NSUInteger count = items.count;
		MATTER_UI_LOG("IGDS %{public}s class=%{public}s count=%{public}lu",
			selectorName, MatterUIRuntimeClassName(result), (unsigned long)count);
		NSUInteger limit = MIN(count, (NSUInteger)30);
		for (NSUInteger index = 0; index < limit; index++) {
			MATTER_UI_LOG("IGDS %{public}s[%{public}lu] class=%{public}s",
				selectorName, (unsigned long)index, MatterUIRuntimeClassName([items objectAtIndex:index]));
		}
		if (count > limit) {
			MATTER_UI_LOG("IGDS %{public}s truncated max=30", selectorName);
		}
	} @catch (__unused NSException *exception) {
		MATTER_UI_LOG("IGDS %{public}s inspection unavailable reason=collectionException", selectorName);
	}
}

static void MatterUIInspectIGDSSectionController(id sectionController) {
	if (!sectionController || !MatterDebugLoggingEnabled()) {
		return;
	}
	Class cls = object_getClass(sectionController);
	const char *const sectionSelectors[] = {
		"numberOfItems", "sizeForItemAtIndex:", "cellForItemAtIndex:", "didSelectItemAtIndex:",
		"didDeselectItemAtIndex:", "inset", "minimumLineSpacing", "minimumInteritemSpacing",
		"workingRangeSize", "supportedElementKinds"
	};
	for (const char *name : sectionSelectors) {
		SEL selector = NSSelectorFromString([NSString stringWithUTF8String:name]);
		MATTER_UI_LOG("IGDS selector %{public}s=%{public}s", name,
			[sectionController respondsToSelector:selector] ? "YES" : "NO");
	}

	SEL numberSelector = NSSelectorFromString(@"numberOfItems");
	if ([sectionController respondsToSelector:numberSelector]) {
		Method method = class_getInstanceMethod(cls, numberSelector);
		if (MatterUIMethodHasSimpleSignature(method, 2, 'q', 0) &&
		    MatterUIInstallScopedIGDSHook(cls, numberSelector, (IMP)MatterIGDSNumberOfItemsHook,
			    &MatterOriginalIGDSNumberOfItems, &MatterIGDSNumberOfItemsHookInstalled)) {
			MATTER_UI_LOG("IGDS hook installed selector=numberOfItems");
		} else {
			MATTER_UI_LOG("IGDS hook unavailable selector=numberOfItems reason=signatureOrInstallFailed");
		}
	}

	SEL cellSelector = NSSelectorFromString(@"cellForItemAtIndex:");
	if ([sectionController respondsToSelector:cellSelector]) {
		Method method = class_getInstanceMethod(cls, cellSelector);
		if (MatterUIMethodHasSimpleSignature(method, 3, '@', 'q') &&
		    MatterUIInstallScopedIGDSHook(cls, cellSelector, (IMP)MatterIGDSCellForItemAtIndexHook,
			    &MatterOriginalIGDSCellForItemAtIndex, &MatterIGDSCellForItemHookInstalled)) {
			MATTER_UI_LOG("IGDS hook installed selector=cellForItemAtIndex:");
		} else {
			MATTER_UI_LOG("IGDS hook unavailable selector=cellForItemAtIndex: reason=signatureOrInstallFailed");
		}
	}

	SEL selectSelector = NSSelectorFromString(@"didSelectItemAtIndex:");
	if ([sectionController respondsToSelector:selectSelector]) {
		Method method = class_getInstanceMethod(cls, selectSelector);
		if (MatterUIMethodHasSimpleSignature(method, 3, 'v', 'q') &&
		    MatterUIInstallScopedIGDSHook(cls, selectSelector, (IMP)MatterIGDSDidSelectItemAtIndexHook,
			    &MatterOriginalIGDSDidSelectItemAtIndex, &MatterIGDSDidSelectItemHookInstalled)) {
			MATTER_UI_LOG("IGDS hook installed selector=didSelectItemAtIndex:");
		} else {
			MATTER_UI_LOG("IGDS hook unavailable selector=didSelectItemAtIndex: reason=signatureOrInstallFailed");
		}
	}

	SEL viewModelsSelector = NSSelectorFromString(@"sectionController:viewModelsForObject:");
	BOOL hasViewModelsSelector = [sectionController respondsToSelector:viewModelsSelector];
	MATTER_UI_LOG("IGDS selector sectionController:viewModelsForObject:=%{public}s",
		hasViewModelsSelector ? "YES" : "NO");
	if (hasViewModelsSelector) {
		Method method = class_getInstanceMethod(cls, viewModelsSelector);
		if (MatterUIMethodHasSignatureCodes(method, 4, '@', "@@") &&
		    MatterUIInstallScopedIGDSHook(cls, viewModelsSelector, (IMP)MatterIGDSViewModelsForObjectHook,
			    &MatterOriginalIGDSViewModelsForObject, &MatterIGDSViewModelsForObjectHookInstalled)) {
			MATTER_UI_LOG("IGDS hook installed selector=sectionController:viewModelsForObject:");
		} else {
			MATTER_UI_LOG("IGDS hook unavailable selector=sectionController:viewModelsForObject: reason=signatureOrInstallFailed");
		}
	}

	SEL cellViewModelSelector = NSSelectorFromString(@"sectionController:cellForViewModel:atIndex:");
	BOOL hasCellViewModelSelector = [sectionController respondsToSelector:cellViewModelSelector];
	MATTER_UI_LOG("IGDS selector sectionController:cellForViewModel:atIndex:=%{public}s",
		hasCellViewModelSelector ? "YES" : "NO");
	if (hasCellViewModelSelector) {
		Method method = class_getInstanceMethod(cls, cellViewModelSelector);
		if (MatterUIMethodHasSignatureCodes(method, 5, '@', "@@q") &&
		    MatterUIInstallScopedIGDSHook(cls, cellViewModelSelector,
			    (IMP)MatterIGDSCellForViewModelAtIndexHook, &MatterOriginalIGDSCellForViewModelAtIndex,
			    &MatterIGDSCellForViewModelHookInstalled)) {
			MATTER_UI_LOG("IGDS hook installed selector=sectionController:cellForViewModel:atIndex:");
		} else {
			MATTER_UI_LOG("IGDS hook unavailable selector=sectionController:cellForViewModel:atIndex: reason=signatureOrInstallFailed");
		}
	}

	SEL selectViewModelSelector = NSSelectorFromString(@"sectionController:didSelectItemAtIndex:viewModel:");
	BOOL hasSelectViewModelSelector = [sectionController respondsToSelector:selectViewModelSelector];
	MATTER_UI_LOG("IGDS selector sectionController:didSelectItemAtIndex:viewModel:=%{public}s",
		hasSelectViewModelSelector ? "YES" : "NO");
	if (hasSelectViewModelSelector) {
		Method method = class_getInstanceMethod(cls, selectViewModelSelector);
		if (MatterUIMethodHasSignatureCodes(method, 5, 'v', "@q@") &&
		    MatterUIInstallScopedIGDSHook(cls, selectViewModelSelector,
			    (IMP)MatterIGDSDidSelectViewModelAtIndexHook,
			    &MatterOriginalIGDSDidSelectViewModelAtIndex, &MatterIGDSDidSelectViewModelHookInstalled)) {
			MATTER_UI_LOG("IGDS hook installed selector=sectionController:didSelectItemAtIndex:viewModel:");
		} else {
			MATTER_UI_LOG("IGDS hook unavailable selector=sectionController:didSelectItemAtIndex:viewModel: reason=signatureOrInstallFailed");
		}
	}

	const char *const providerSelectors[] = {
		"items", "models", "viewModels", "dataSource", "sectionModel", "configuration",
		"listItems", "rows", "entries"
	};
	BOOL providerExposed = NO;
	for (const char *name : providerSelectors) {
		SEL selector = NSSelectorFromString([NSString stringWithUTF8String:name]);
		BOOL responds = [sectionController respondsToSelector:selector];
		MATTER_UI_LOG("IGDS selector %{public}s=%{public}s", name, responds ? "YES" : "NO");
		if (!responds) {
			continue;
		}
		Method method = class_getInstanceMethod(cls, selector);
		if (!MatterUIMethodHasObjectSignature(method, 2)) {
			MATTER_UI_LOG("IGDS provider unavailable selector=%{public}s reason=signatureUnavailable", name);
			continue;
		}
		providerExposed = YES;
		@try {
			MatterUIInspectIGDSProviderResult(name, MatterUIReadObjectSelector(sectionController, selector));
		} @catch (__unused NSException *exception) {
			MATTER_UI_LOG("IGDS provider unavailable selector=%{public}s reason=readException", name);
		}
	}
	if (!providerExposed) {
		MATTER_UI_LOG("IGDS settings model provider not exposed via inspected selectors");
	}
	MatterUIInspectIGDSMethodNames(cls);
}

static void MatterSettingsViewDidAppearHook(id self, SEL selector, BOOL animated) {
	MatterViewDidAppearIMP original = MatterOriginalSettingsViewDidAppear;
	if (!original) {
		return;
	}
	original(self, selector, animated);
	if (MatterUIClassIsVerifiedSettingsController(object_getClass(self))) {
		MatterUIInspectSettingsAppearance((UIViewController *)self);
	}
}

static void MatterSettingsViewDidLoadHook(id self, SEL selector) {
	MatterViewDidLoadIMP original = MatterOriginalSettingsViewDidLoad;
	if (!original) {
		return;
	}
	original(self, selector);
	if (MatterUIClassIsVerifiedSettingsController(object_getClass(self))) {
		MATTER_UI_LOG("settings loaded class=%{public}s", MatterUIRuntimeClassName(self));
		MatterUIInspectSettingsController(self);
	}
}

static void MatterInstallSettingsViewDidLoadHook(Class settingsClass) {
	static BOOL installed = NO;
	if (installed || !MatterUIClassIsVerifiedSettingsController(settingsClass)) {
		return;
	}

	SEL selector = @selector(viewDidLoad);
	Method inheritedOrOwnMethod = class_getInstanceMethod(settingsClass, selector);
	char *returnType = inheritedOrOwnMethod ? method_copyReturnType(inheritedOrOwnMethod) : NULL;
	BOOL validSignature = inheritedOrOwnMethod && method_getNumberOfArguments(inheritedOrOwnMethod) == 2 &&
		returnType && returnType[0] == 'v';
	free(returnType);
	const char *typeEncoding = validSignature ? method_getTypeEncoding(inheritedOrOwnMethod) : NULL;
	if (!typeEncoding) {
		MATTER_UI_LOG("settings load hook unavailable reason=selectorOrSignatureMissing");
		return;
	}

	Method ownMethod = MatterUIOwnMethod(settingsClass, selector);
	if (ownMethod) {
		IMP original = method_getImplementation(ownMethod);
		if (!original || original == (IMP)MatterSettingsViewDidLoadHook) {
			MATTER_UI_LOG("settings load hook unavailable reason=originalMissing");
			return;
		}
		MatterOriginalSettingsViewDidLoad = (MatterViewDidLoadIMP)original;
		IMP replaced = method_setImplementation(ownMethod, (IMP)MatterSettingsViewDidLoadHook);
		if (!replaced) {
			MatterOriginalSettingsViewDidLoad = NULL;
			MATTER_UI_LOG("settings load hook unavailable reason=methodInstallFailed");
			return;
		}
		if (replaced != (IMP)MatterSettingsViewDidLoadHook) {
			MatterOriginalSettingsViewDidLoad = (MatterViewDidLoadIMP)replaced;
		}
	} else {
		MatterOriginalSettingsViewDidLoad = (MatterViewDidLoadIMP)method_getImplementation(inheritedOrOwnMethod);
		if (!MatterOriginalSettingsViewDidLoad ||
		    !class_addMethod(settingsClass, selector, (IMP)MatterSettingsViewDidLoadHook, typeEncoding)) {
			MatterOriginalSettingsViewDidLoad = NULL;
			MATTER_UI_LOG("settings load hook unavailable reason=methodInstallFailed");
			return;
		}
	}

	installed = YES;
	MATTER_UI_LOG("settings load hook installed class=%{public}s selector=viewDidLoad",
		class_getName(settingsClass));
}

static void MatterInstallSettingsLifecycleHook(Class settingsClass) {
	static BOOL installed = NO;
	if (!MatterUIClassIsVerifiedSettingsController(settingsClass)) {
		return;
	}
	MatterInstallSettingsViewDidLoadHook(settingsClass);
	if (installed) {
		return;
	}

	SEL selector = @selector(viewDidAppear:);
	Method inheritedOrOwnMethod = class_getInstanceMethod(settingsClass, selector);
	const char *typeEncoding = inheritedOrOwnMethod ? method_getTypeEncoding(inheritedOrOwnMethod) : NULL;
	if (!typeEncoding) {
		MATTER_UI_LOG("settings lifecycle hook unavailable reason=selectorMissing");
		return;
	}

	// Keep the lifecycle override local to the verified controller class.
	Method ownMethod = MatterUIOwnMethod(settingsClass, selector);
	if (ownMethod) {
		IMP existingImplementation = method_getImplementation(ownMethod);
		if (!existingImplementation) {
			MATTER_UI_LOG("settings lifecycle hook unavailable reason=originalMissing");
			return;
		}
		MatterOriginalSettingsViewDidAppear = (MatterViewDidAppearIMP)existingImplementation;
		IMP replacedImplementation = method_setImplementation(ownMethod, (IMP)MatterSettingsViewDidAppearHook);
		if (!replacedImplementation) {
			method_setImplementation(ownMethod, existingImplementation);
			MatterOriginalSettingsViewDidAppear = NULL;
			MATTER_UI_LOG("settings lifecycle hook unavailable reason=originalMissing");
			return;
		}
		if (replacedImplementation != (IMP)MatterSettingsViewDidAppearHook) {
			MatterOriginalSettingsViewDidAppear = (MatterViewDidAppearIMP)replacedImplementation;
		}
	} else {
		MatterOriginalSettingsViewDidAppear = (MatterViewDidAppearIMP)method_getImplementation(inheritedOrOwnMethod);
		if (!MatterOriginalSettingsViewDidAppear ||
		    !class_addMethod(settingsClass, selector, (IMP)MatterSettingsViewDidAppearHook, typeEncoding)) {
			MatterOriginalSettingsViewDidAppear = NULL;
			MATTER_UI_LOG("settings lifecycle hook unavailable reason=methodInstallFailed");
			return;
		}
	}

	if (!MatterOriginalSettingsViewDidAppear) {
		MATTER_UI_LOG("settings lifecycle hook unavailable reason=originalMissing");
		return;
	}
	installed = YES;
	MATTER_UI_LOG("settings lifecycle hook installed class=%{public}s selector=viewDidAppear:",
		class_getName(settingsClass));
}

static void MatterInstallSettingsLifecycleHookIfTarget(id controller) {
	Class cls = controller ? object_getClass(controller) : Nil;
	if (MatterUIClassIsVerifiedSettingsController(cls)) {
		MatterInstallSettingsLifecycleHook(cls);
	}
}

%hook UINavigationController

- (void)pushViewController:(UIViewController *)viewController animated:(BOOL)animated {
	MatterInstallSettingsLifecycleHookIfTarget(viewController);
	%orig(viewController, animated);
	BOOL isViewController = MatterUIIsInstanceOfClassNamed(viewController, "UIViewController");
	MATTER_UI_LOG("push class=%{public}s title=%{public}s isViewController=%{public}s depth=%{public}lu",
		MatterUIRuntimeClassName(viewController), MatterUIControllerTitleToken(viewController),
		isViewController ? "YES" : "NO", (unsigned long)self.viewControllers.count);
	MatterUIInspectSettingsController(viewController);
}

%end

%hook UIViewController

- (void)presentViewController:(UIViewController *)viewControllerToPresent
					animated:(BOOL)animated
					completion:(void (^)(void))completion {
	MatterInstallSettingsLifecycleHookIfTarget(viewControllerToPresent);
	%orig(viewControllerToPresent, animated, completion);
	MATTER_UI_LOG("present presenterClass=%{public}s presentedClass=%{public}s presentedTitle=%{public}s",
		MatterUIRuntimeClassName(self), MatterUIRuntimeClassName(viewControllerToPresent),
		MatterUIControllerTitleToken(viewControllerToPresent));
	MatterUIInspectSettingsController(viewControllerToPresent);
}

%end

%ctor {
	MatterInstallSettingsLifecycleHook(objc_getClass("BCNSettings.BCNSettingsViewController"));
	MATTER_UI_LOG("UI discovery enabled");
}
