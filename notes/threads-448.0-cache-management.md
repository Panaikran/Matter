# Matter cache management

Validated with Matter 0.1.0-30 / 0.1.0 RC1 on Threads 448.0.0, including LiveContainer and direct-sideload environments.

## Approved scope

- The running app's `NSCachesDirectory` contents.
- The running app's `NSTemporaryDirectory()` contents, only after root validation succeeds.
- Shared `NSURLCache` responses are cleared with `removeAllCachedResponses`.

Cache Size totals files in the accepted Caches and temporary roots; it does not estimate `NSURLCache` separately. Clear Cache preserves each root and removes only its children. Child symlinks are skipped, and traversal must remain contained within the accepted operating root. Filesystem errors are counted without logging paths or filenames.

Matter does not clear Documents, Application Support, Preferences, Cookies, databases, account/session state, Keychain items, drafts, downloaded documents, or other Library directories. Cache Size represents Matter's safely clearable cache scope, not total Threads application storage.

## Temporary-root validation

`NSCachesDirectory` is resolved first, and its validated `Library/Caches` structure provides the trusted data-container anchor. Matter constructs the expected `<container>/tmp` alias and resolves that alias only for validation. It accepts temporary storage only if the canonical resolved alias equals the canonical actual `NSTemporaryDirectory()` URL or both existing directories have matching filesystem resource identifiers.

LiveContainer may map the trusted `tmp` alias to a canonical physical location outside the anchor. Once the strong alias-equivalence proof succeeds, Matter retains that authorization and uses the canonical actual temporary directory as the operating root. Descendant containment and child-symlink checks remain relative to that root. If proof fails, Matter skips the temporary root and continues safely with accepted Caches storage.

Structural root outcomes are separate from file-operation errors. Debug logging can report root labels, accepted/skipped state, reason codes, and aggregate counts, but never paths, targets, filenames, resource identifiers, or file contents.

## Calculation, clearing, and startup

File traversal and deletion run asynchronously on Matter's cache queue. Manual clearing requires confirmation, refreshes Cache Size afterward, and reports unsafe-root skips separately from file failures. A final size of at most 5 MB is treated as effectively cleared only under the existing error rules; unsafe roots are never hidden by this threshold.

Clear Cache on Startup defaults OFF. When enabled, one process-local guard schedules one asynchronous clear per new Threads process after launch initialization. Background/foreground changes do not repeat the operation. The preference migration preserves an existing RC1 startup-clear choice under the new `com.panaikran.matter` namespace.
