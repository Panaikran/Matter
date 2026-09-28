#import <Foundation/Foundation.h>
#import <stdint.h>

typedef struct {
	NSUInteger total;
	NSUInteger notFound;
	NSUInteger permission;
	NSUInteger busy;
	NSUInteger cancelled;
	NSUInteger invalidPath;
	NSUInteger io;
	NSUInteger other;
} MatterCacheErrorSummary;

typedef struct {
	uint64_t bytes;
	MatterCacheErrorSummary errors;
	NSUInteger rootsAccepted;
	NSUInteger rootsSkippedUnsafe;
	BOOL available;
} MatterCacheSizeResult;

typedef struct {
	uint64_t bytesBefore;
	uint64_t bytesAfter;
	uint64_t bytesFreed;
	MatterCacheErrorSummary errors;
	NSUInteger rootsAccepted;
	NSUInteger rootsSkippedUnsafe;
} MatterCacheClearResult;

@interface MatterCacheManager : NSObject

+ (void)asynchronouslyCalculateCacheSizeWithCompletion:(void (^)(MatterCacheSizeResult result))completion;
+ (BOOL)asynchronouslyClearCacheWithCompletion:(void (^)(MatterCacheClearResult result))completion;
+ (BOOL)isClearInProgress;

@end
