//
//  FABigDataCache.m
//
//  Created by Finn Wilke on 30.07.13.
//  Copyright (c) 2013 Finn Wilke. All rights reserved.
//

#import "FABigDataCache.h"
#import "NSObject+PerformBlock.h"
#import "FACache+Private.h"

@interface FABigDataCachedItem : FACachedItem <NSDiscardableContent>

@property (assign) BOOL dirty;
@property (assign) NSUInteger objectHash;
@property (readonly) NSInteger accessCount;

- (BOOL)isContentDiscarded;
- (void)commitToPersistentStorage;
- (void)purgeDataFromMemory;
- (void)purgeFromPersistentStorage;

@end

@implementation FABigDataCache

// commits all data to the backing cache
- (void)commitAllItemsToPersistentStoragePurgingFromMemory:(BOOL)purgingFromMemory
{
    [self.lock lock];
    
    for (id item in self.allObjects) {
        if ([item isMemberOfClass:[FABigDataCachedItem class]]) {
            FABigDataCachedItem *cachedItem = item;
            
            if (cachedItem.dirty) {
                [cachedItem commitToPersistentStorage];
            }
            
            if (purgingFromMemory) {
                [cachedItem purgeDataFromMemory];
            }
        }
    }
    
    [self.lock unlock];
}

- (void)evictAllObjects
{
    [self commitAllItemsToPersistentStoragePurgingFromMemory:YES];
    [super evictAllObjects];
}

- (NSUInteger)loadedObjectCount
{
    [self.lock lock];
    
    NSUInteger count = 0;
    
    for (FABigDataCachedItem *item in self.allObjects) {
        if ([item isKindOfClass:[FABigDataCachedItem class]]) {
            if (![item isContentDiscarded]) {
                count++;
            }
        }
    }
    
    [self.lock unlock];
    
    return count;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<FABigDataCache with name: \"%@\", object count: %i (loaded)/%i (total), total cost:%i>", self.name, self.loadedObjectCount, self.objectCount, self.totalCost];
}

- (void)purgeAllItemsFromPersistentStorage
{
    [self.lock lock];
    
    [[NSFileManager defaultManager] removeItemAtPath:[self filePath] error:nil];
    
    [self.lock unlock];
}

- (NSString *)filePath
{
    [self.lock lock];
    
    NSArray *myPathList = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *myPath = [myPathList objectAtIndex:0];
    myPath = [myPath stringByAppendingPathComponent:self.name];
    
    [[NSFileManager defaultManager] createDirectoryAtPath:myPath withIntermediateDirectories:YES attributes:nil error:nil];
    
    [self.lock unlock];
    
    return myPath;
}

- (void)setObject:(id)obj forKey:(id)key cost:(NSUInteger)cost expirationTime:(NSTimeInterval)expirationTime
{
    if (obj == nil) {
        return;
    }
    
    FABigDataCachedItem *item = [[FABigDataCachedItem alloc] initWithCache:self key:key object:obj];
    item.expirationTime = expirationTime;
    item.cost = cost;
    item.dirty = YES;
    
    [self setCachedItem:item forKey:key];
    
    DDLogModel(@"Adding object %@ with key: %@ to cache: \"%@\", new object count: %i", [obj description], key, self.name, self.objectCount);
}

- (void)cleanObjectFromMemoryForKey:(id)key
{
    id item = [self cachedItemForKey:key];
    
    if ([item isKindOfClass:[NSNull class]]) {
        return;
    }
    
    FABigDataCachedItem *cacheItem = item;
    [cacheItem purgeFromPersistentStorage];
}

@end

@implementation FABigDataCachedItem {
    NSInteger _accessCount;
    dispatch_semaphore_t _saveToDiskSemaphore;
    id _object;
}

- (instancetype)initWithCache:(FACache *)cache key:(id)key object:(id)object
{
    self = [super initWithCache:cache key:key object:object];
    
    if (self) {
        // Access object to force it to be purged if not "retained"
        [self object];
        
        _saveToDiskSemaphore = dispatch_semaphore_create(1);
    }
    
    return self;
}

- (instancetype)init
{
    self = [super init];
    
    if (self) {
        _accessCount = 0;
        _saveToDiskSemaphore = dispatch_semaphore_create(1);
    }
    
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder
{
    self = [super initWithCoder:aDecoder];
    
    if (self) {
        _accessCount = 0;
        _saveToDiskSemaphore = dispatch_semaphore_create(1);
    }
    
    return self;
}

- (void)encodeWithCoder:(NSCoder *)aCoder
{
    [self.lock lock];
    
    [self commitToPersistentStorage];
    [self purgeDataFromMemory];
    [super encodeWithCoder:aCoder];
    
    [self.lock unlock];
}

- (NSString *)filename
{
    return [((FABigDataCache *)self.cache).filePath stringByAppendingPathComponent :[self.cacheKey base64EncodedString]];
}

- (id)object
{
    [self beginContentAccess];
    id object = _object;
    
    // FIXME: This is needed to ensure an "autoreleased" kind of behavior, that will time out the access after some time
    // At the moment set to 0 seconds so it will time out when the current event loop is done
    [self performBlock:^{
        [self endContentAccess];
    } afterDelay:30];
    
    return object;
}

- (void)setObject:(id)object
{
    [self beginContentAccess];
    
    _object = object;
    self.dirty = _object != object;
    self.objectHash = [object hash];
    
    [self endContentAccess];
}

- (BOOL)beginContentAccess
{
    _accessCount++;
    
    return [self loadDataFromPersistentStorage];
}

- (void)endContentAccess
{
    if (self.accessCount > 0) {
        _accessCount--;
    }
    
    [self discardContentIfPossible];
}

- (void)endAllContentAccess
{
    while (self.accessCount > 0) {
        [self endContentAccess];
    }
}

- (void)discardContentIfPossible
{
    [self.lock lock];
    
    if (_accessCount <= 0) {
        _accessCount = 0;
        
        self.dirty = self.dirty || self.objectHash != [self.object hash];
        
        if (self.dirty) {
            [self commitToPersistentStorage];
        }
        
        [self purgeDataFromMemory];
    }
    
    [self.lock unlock];
}

- (BOOL)isContentDiscarded
{
    [self.lock lock];
    BOOL discarded = self.object == nil;
    [self.lock unlock];
    
    return discarded;
}

- (void)purgeDataFromMemory
{
    [self.lock lock];
    
    _object = nil;
    
    [self.lock unlock];
}

- (void)objectWithBlock:(void (^)(BOOL success, id object))callback
{
    [self.lock lock];
    
    if (_object != nil) {
        BOOL success = [self beginContentAccess];
        
        id object = _object;
        [self.lock unlock];
        
        callback(success, object);
        
        [self endContentAccess];
    } else {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            dispatch_semaphore_wait(_saveToDiskSemaphore, DISPATCH_TIME_FOREVER);
            
            BOOL success = [self beginContentAccess];
            id object = _object;
            
            dispatch_semaphore_signal(_saveToDiskSemaphore);
            
            callback(success, object);
            
            [self endContentAccess];
        });
        
        [self.lock unlock];
    }
}

- (BOOL)loadDataFromPersistentStorage
{
    [self.lock lock];
    
    if (_object == nil) {
        _object = [NSKeyedUnarchiver unarchiveObjectWithFile:[self filename]];
        self.dirty = NO;
    }
    
    BOOL value = _object != nil;
    
    [self.lock unlock];
    
    return value;
}

- (void)commitToPersistentStorage
{
    [self.lock lock];
    
    
    if (_object != nil) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            dispatch_semaphore_wait(_saveToDiskSemaphore, DISPATCH_TIME_FOREVER);
            
            if ([NSKeyedArchiver archiveRootObject:_object toFile:[self filename]]) {
                self.dirty = NO;
                
                dispatch_semaphore_signal(_saveToDiskSemaphore);
            }
        });
    }
    
    [self.lock unlock];
}

- (void)purgeFromPersistentStorage
{
    [self.lock lock];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        dispatch_semaphore_wait(_saveToDiskSemaphore, DISPATCH_TIME_FOREVER);
        
        [[NSFileManager defaultManager] removeItemAtPath:[self filename] error:nil];
        
        dispatch_semaphore_signal(_saveToDiskSemaphore);
    });
    
    [self.lock unlock];
}

- (void)dealloc
{
    // We are leaving and nobody can stop us!
    [self endAllContentAccess];
    
    // Wait for any activity to occur and dealloc the semaphore
    // FIXME: Is this needed?
    dispatch_semaphore_wait(_saveToDiskSemaphore, DISPATCH_TIME_FOREVER);
    dispatch_semaphore_t oldSemaphore = _saveToDiskSemaphore;
    _saveToDiskSemaphore = NULL;
    dispatch_semaphore_signal(oldSemaphore);
}

@end
