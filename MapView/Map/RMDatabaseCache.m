//
//  RMDatabaseCache.m
//
// Copyright (c) 2008-2009, Route-Me Contributors
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// * Redistributions of source code must retain the above copyright notice, this
//   list of conditions and the following disclaimer.
// * Redistributions in binary form must reproduce the above copyright notice,
//   this list of conditions and the following disclaimer in the documentation
//   and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

#import "RMDatabaseCache.h"
#import "FMDatabase.h"
#import "FMDatabaseQueue.h"
#import "RMTileImage.h"
#import "RMTile.h"

#define kWriteQueueLimit 15

@interface RMDatabaseCache ()

- (NSUInteger)count;
- (NSUInteger)countTiles;
- (void)touchTile:(RMTile)tile withKey:(NSString *)cacheKey;
- (void)purgeTiles:(NSUInteger)count;

@end

#pragma mark -

@implementation RMDatabaseCache
{
    // Database
    FMDatabaseQueue *_queue;

    NSUInteger _tileCount;
    NSOperationQueue *_writeQueue;
    NSRecursiveLock *_writeQueueLock;

    // Cache
    RMCachePurgeStrategy _purgeStrategy;
    NSUInteger _capacity;
    NSUInteger _minimalPurge;
    NSTimeInterval _expiryPeriod;
}

@synthesize databasePath = _databasePath;

+ (NSString *)dbPathUsingCacheDir:(BOOL)useCacheDir
{
	NSArray *paths;

	if (useCacheDir)
		paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
	else
		paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);

	if ([paths count] > 0) // Should only be one...
	{
		NSString *cachePath = [paths objectAtIndex:0];

		// check for existence of cache directory
		if ( ![[NSFileManager defaultManager] fileExistsAtPath: cachePath])
		{
			// create a new cache directory
			[[NSFileManager defaultManager] createDirectoryAtPath:cachePath withIntermediateDirectories:NO attributes:nil error:nil];
		}

		return [cachePath stringByAppendingPathComponent:@"RMTileCache.db"];
	}

	return nil;
}

- (void)configureDBForFirstUse
{
    [_queue inDatabase:^(FMDatabase *db) {
        [[db executeQuery:@"PRAGMA synchronous=OFF"] close];
        [[db executeQuery:@"PRAGMA journal_mode=OFF"] close];
        [[db executeQuery:@"PRAGMA cache-size=100"] close];
        [[db executeQuery:@"PRAGMA count_changes=OFF"] close];
        // LeadNav customization for optimizing performance; see http://www.sqlite.org/intern-v-extern-blob.html
        [[db executeQuery:@"PRAGMA page_size=8192"] close];
        [db executeUpdate:@"CREATE TABLE IF NOT EXISTS ZCACHE (tile_hash INTEGER NOT NULL, cache_key VARCHAR(25) NOT NULL, last_used DOUBLE NOT NULL, data BLOB NOT NULL)"];
        [db executeUpdate:@"CREATE UNIQUE INDEX IF NOT EXISTS main_index ON ZCACHE(tile_hash, cache_key)"];
        [db executeUpdate:@"CREATE INDEX IF NOT EXISTS last_used_index ON ZCACHE(last_used)"];
        // LeadNav customization to prevent user-saved areas from being purged from the cache
        [db executeUpdate:@"ALTER TABLE ZCACHE ADD COLUMN leadnav_area_count INTEGER NOT NULL DEFAULT 0"];
    }];
}

- (id)initWithDatabase:(NSString *)path
{
	if (!(self = [super init]))
		return nil;

	self.databasePath = path;

    _writeQueue = [NSOperationQueue new];
    [_writeQueue setMaxConcurrentOperationCount:1];
    _writeQueueLock = [NSRecursiveLock new];

	RMLog(@"Opening database at %@", path);

    _queue = [FMDatabaseQueue databaseQueueWithPath:path];

	if (!_queue)
	{
		RMLog(@"Could not connect to database");

        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];

        return nil;
	}

    [_queue inDatabase:^(FMDatabase *db) {
        [db setCrashOnErrors:NO];
        [db setShouldCacheStatements:TRUE];
    }];

	[self configureDBForFirstUse];

    _tileCount = [self countTiles];

	return self;	
}

- (id)initUsingCacheDir:(BOOL)useCacheDir
{
	return [self initWithDatabase:[RMDatabaseCache dbPathUsingCacheDir:useCacheDir]];
}

- (void)dealloc
{
    [_writeQueueLock lock];
     _writeQueue = nil;
    [_writeQueueLock unlock];
     _writeQueueLock = nil;
     _queue = nil;
}

- (void)setPurgeStrategy:(RMCachePurgeStrategy)theStrategy
{
	_purgeStrategy = theStrategy;
}

- (void)setCapacity:(NSUInteger)theCapacity
{
	_capacity = theCapacity;
}

- (NSUInteger)capacity
{
    return _capacity;
}

- (void)setMinimalPurge:(NSUInteger)theMinimalPurge
{
	_minimalPurge = theMinimalPurge;
}

- (void)setExpiryPeriod:(NSTimeInterval)theExpiryPeriod
{
    _expiryPeriod = theExpiryPeriod;
    
    srand((unsigned int)time(NULL));
}

- (unsigned long long)fileSize
{
    return [[[NSFileManager defaultManager] attributesOfItemAtPath:self.databasePath error:nil] fileSize];
}

- (UIImage *)cachedImage:(RMTile)tile withCacheKey:(NSString *)aCacheKey
{
//	RMLog(@"DB cache check for tile %d %d %d", tile.x, tile.y, tile.zoom);

    __block UIImage *cachedImage = nil;

    [_writeQueueLock lock];

    [_queue inDatabase:^(FMDatabase *db)
     {
         FMResultSet *results = [db executeQuery:@"SELECT data FROM ZCACHE WHERE tile_hash = ? AND cache_key = ?", [RMTileCache tileHash:tile], aCacheKey];

         if ([db hadError])
         {
             RMLog(@"DB error while fetching tile data: %@", [db lastErrorMessage]);
             return;
         }

         NSData *data = nil;

         if ([results next])
         {
             data = [results dataForColumnIndex:0];
             if (data) cachedImage = [UIImage imageWithData:data];
         }

         [results close];
     }];

    [_writeQueueLock unlock];

    if (_capacity != 0 && _purgeStrategy == RMCachePurgeStrategyLRU)
        [self touchTile:tile withKey:aCacheKey];

    if (_expiryPeriod > 0)
    {
        if (rand() % 100 == 0)
        {
            [_writeQueueLock lock];

            [_queue inDatabase:^(FMDatabase *db)
             {
                 // LeadNav customization to prevent user-saved areas from being purged from the cache
                 //BOOL result = [db executeUpdate:@"DELETE FROM ZCACHE WHERE last_used < ?", [NSDate dateWithTimeIntervalSinceNow:-_expiryPeriod]];
              BOOL result = [db executeUpdate:@"DELETE FROM ZCACHE WHERE last_used < ? AND leadnav_area_count = 0", [NSDate dateWithTimeIntervalSinceNow:-self->_expiryPeriod]];

                 if (result == NO)
                     RMLog(@"Error expiring cache");

                 [[db executeQuery:@"VACUUM"] close];
             }];

            [_writeQueueLock unlock];

            _tileCount = [self countTiles];
        }
    }

//    RMLog(@"DB cache     hit    tile %d %d %d (%@)", tile.x, tile.y, tile.zoom, [RMTileCache tileHash:tile]);

	return cachedImage;
}

- (void)addImage:(UIImage *)image forTile:(RMTile)tile withCacheKey:(NSString *)aCacheKey
{
    // TODO: Converting the image here (again) is not so good...
	NSData *data = UIImagePNGRepresentation(image);

    if (_capacity != 0)
    {
        NSUInteger tilesInDb = [self count];

        if (_capacity <= tilesInDb && _expiryPeriod == 0)
            [self purgeTiles:MAX(_minimalPurge, 1+tilesInDb-_capacity)];

//        RMLog(@"DB cache     insert tile %d %d %d (%@)", tile.x, tile.y, tile.zoom, [RMTileCache tileHash:tile]);

        // Don't add new images to the database while there are still more than kWriteQueueLimit
        // insert operations pending. This prevents some memory issues.

        BOOL skipThisTile = NO;

        [_writeQueueLock lock];

        if ([_writeQueue operationCount] > kWriteQueueLimit)
            skipThisTile = YES;

        [_writeQueueLock unlock];

        if (skipThisTile)
            return;

        [_writeQueue addOperationWithBlock:^{
            __block BOOL result = NO;

          [self->_writeQueueLock lock];

          [self->_queue inDatabase:^(FMDatabase *db)
             {
                 result = [db executeUpdate:@"INSERT OR IGNORE INTO ZCACHE (tile_hash, cache_key, last_used, data) VALUES (?, ?, ?, ?)", [RMTileCache tileHash:tile], aCacheKey, [NSDate date], data];
             }];

          [self->_writeQueueLock unlock];

            if (result == NO)
                RMLog(@"Error occured adding data");
            else
              self->_tileCount++;
        }];
	}
}

#pragma mark -

- (NSUInteger)count
{
    return _tileCount;
}

- (NSUInteger)countTiles
{
    __block NSUInteger count = 0;

    [_writeQueueLock lock];

    [_queue inDatabase:^(FMDatabase *db)
     {
         FMResultSet *results = [db executeQuery:@"SELECT COUNT(tile_hash) FROM ZCACHE"];

         if ([results next])
             count = [results intForColumnIndex:0];
         else
             RMLog(@"Unable to count columns");

         [results close];
     }];

    [_writeQueueLock unlock];

	return count;
}

- (void)purgeTiles:(NSUInteger)count
{
    RMLog(@"purging %lu old tiles from the db cache", (unsigned long)count);

    [_writeQueueLock lock];

    [_queue inDatabase:^(FMDatabase *db)
     {
         // LeadNav customization to prevent user-saved areas from being purged from the cache
         //BOOL result = [db executeUpdate:@"DELETE FROM ZCACHE WHERE tile_hash IN (SELECT tile_hash FROM ZCACHE ORDER BY last_used LIMIT ?)", [NSNumber numberWithUnsignedLongLong:count]];
         BOOL result = [db executeUpdate:@"DELETE FROM ZCACHE WHERE tile_hash IN (SELECT tile_hash FROM ZCACHE WHERE leadnav_area_count = 0 ORDER BY last_used LIMIT ?)", [NSNumber numberWithUnsignedLongLong:count]];

         if (result == NO)
             RMLog(@"Error purging cache");

         [[db executeQuery:@"VACUUM"] close];
     }];

    [_writeQueueLock unlock];

    _tileCount = [self countTiles];
}

- (void)removeAllCachedImages 
{
    RMLog(@"removing all tiles from the db cache");

    [_writeQueue addOperationWithBlock:^{
      [self->_writeQueueLock lock];

      [self->_queue inDatabase:^(FMDatabase *db)
         {
             BOOL result = [db executeUpdate:@"DELETE FROM ZCACHE"];

             if (result == NO)
                 RMLog(@"Error purging cache");

             [[db executeQuery:@"VACUUM"] close];
         }];

      [self->_writeQueueLock unlock];

      self->_tileCount = [self countTiles];
    }];
}

- (void)removeAllCachedImagesForCacheKey:(NSString *)cacheKey
{
    RMLog(@"removing tiles for key '%@' from the db cache", cacheKey);

    [_writeQueue addOperationWithBlock:^{
      [self->_writeQueueLock lock];

      [self->_queue inDatabase:^(FMDatabase *db)
         {
             BOOL result = [db executeUpdate:@"DELETE FROM ZCACHE WHERE cache_key = ?", cacheKey];

             if (result == NO)
                 RMLog(@"Error purging cache");
         }];

      [self->_writeQueueLock unlock];

      self->_tileCount = [self countTiles];
    }];
}

// LeadNav customization to allow user-saved areas to be cached indefinitely
- (void)addArea:(NSDictionary *)area forCacheKey:(NSString *)cacheKey
{
    RMLog(@"adding area for key '%@'", cacheKey);
    
    NSArray *tileHashes = [self tileHashesForArea:area];
    
    if (tileHashes.count == 0) {
        return;
    }
    
    NSMutableArray *updates = [NSMutableArray new];
    
    for (int i = 0; i < tileHashes.count; i += 100) {
        NSRange range = NSMakeRange(i, (i + 100 > tileHashes.count) ? tileHashes.count - i : 100);
        NSIndexSet *indexSet = [NSIndexSet indexSetWithIndexesInRange:range];
        NSString *tileHashList = [[tileHashes objectsAtIndexes:indexSet] componentsJoinedByString:@", "];
        NSString *update = [NSString stringWithFormat:@"UPDATE ZCACHE SET leadnav_area_count = leadnav_area_count + 1 WHERE cache_key = '%@' AND tile_hash IN (%@)", cacheKey, tileHashList];
        
        [updates addObject:update];
    }
    
    [_writeQueue addOperationWithBlock:^{
      [self->_writeQueueLock lock];
        
      [self->_queue inDatabase:^(FMDatabase *db)
         {
             [db beginTransaction];
             
             for (NSString *update in updates) {
                 //RMLog(@"%@", update);
                 
                 [db executeUpdate:update];
             }
             
             [db commit];
         }];
        
      [self->_writeQueueLock unlock];
    }];
}

// LeadNav customization to allow user-saved areas to be cached indefinitely
- (void)removeArea:(NSDictionary *)area forCacheKey:(NSString *)cacheKey
{
    RMLog(@"removing area for key '%@'", cacheKey);
    
    NSArray *tileHashes = [self tileHashesForArea:area];
    
    if (tileHashes.count == 0) {
        return;
    }
    
    NSMutableArray *updates = [NSMutableArray new];
    
    for (int i = 0; i < tileHashes.count; i += 100) {
        NSRange range = NSMakeRange(i, (i + 100 > tileHashes.count) ? tileHashes.count - i : 100);
        NSIndexSet *indexSet = [NSIndexSet indexSetWithIndexesInRange:range];
        NSString *tileHashList = [[tileHashes objectsAtIndexes:indexSet] componentsJoinedByString:@", "];
        NSString *update = [NSString stringWithFormat:@"UPDATE ZCACHE SET leadnav_area_count = CASE WHEN leadnav_area_count = 0 THEN 0 ELSE leadnav_area_count - 1 END WHERE cache_key = '%@' AND tile_hash IN (%@)", cacheKey, tileHashList];
        
        [updates addObject:update];
    }
    
    [_writeQueue addOperationWithBlock:^{
      [self->_writeQueueLock lock];
        
      [self->_queue inDatabase:^(FMDatabase *db)
         {
             [db beginTransaction];
             
             for (NSString *update in updates) {
                 //RMLog(@"%@", update);
                 
                 [db executeUpdate:update];
             }
             
             [db commit];
         }];
        
      [self->_writeQueueLock unlock];
    }];
}

// LeadNav customization to calculate all the tile hashes for an area
- (NSArray *)tileHashesForArea:(NSDictionary *)area
{
    NSMutableArray *tileHashes = [NSMutableArray new];
    int minCacheZoom = [[area objectForKey:@"minZoom"] intValue];
    int maxCacheZoom = [[area objectForKey:@"maxZoom"] intValue];
    float minCacheLat = [[area objectForKey:@"southWestLat"] floatValue];
    float maxCacheLat = [[area objectForKey:@"northEastLat"] floatValue];
    float minCacheLon = [[area objectForKey:@"southWestLong"] floatValue];
    float maxCacheLon = [[area objectForKey:@"northEastLong"] floatValue];
    
    if (minCacheLat > maxCacheLat || minCacheLon > maxCacheLon || minCacheZoom > maxCacheZoom) {
        return [tileHashes copy];
    }
    
    int n, xMin, yMax, xMax, yMin;
    
    for (int zoom = minCacheZoom; zoom <= maxCacheZoom; zoom++)
    {
        n = pow(2.0, zoom);
        xMin = floor(((minCacheLon + 180.0) / 360.0) * n);
        yMax = floor((1.0 - (logf(tanf(minCacheLat * M_PI / 180.0) + 1.0 / cosf(minCacheLat * M_PI / 180.0)) / M_PI)) / 2.0 * n);
        xMax = floor(((maxCacheLon + 180.0) / 360.0) * n);
        yMin = floor((1.0 - (logf(tanf(maxCacheLat * M_PI / 180.0) + 1.0 / cosf(maxCacheLat * M_PI / 180.0)) / M_PI)) / 2.0 * n);
        
        for (int x = xMin; x <= xMax; x++)
        {
            for (int y = yMin; y <= yMax; y++)
            {
                [tileHashes addObject:[RMTileCache tileHash:RMTileMake(x, y, zoom)]];
            }
        }
    };
    
    return [tileHashes copy];
}

// LeadNav customization to get the cache size for a cache
- (unsigned long long)cacheSizeForCacheKey:(NSString *)cacheKey
{
    __block NSUInteger cacheSize = 0;
    
    [_writeQueueLock lock];
    
    [_queue inDatabase:^(FMDatabase *db)
     {
         FMResultSet *results = [db executeQuery:@"SELECT SUM(LENGTH(data)) FROM ZCACHE WHERE cache_key = ?", cacheKey];
         
         if ([results next])
             cacheSize = [results intForColumnIndex:0];
         else
             RMLog(@"Unable to calculate the cache size");
         
         [results close];
     }];
    
    [_writeQueueLock unlock];
    
	return cacheSize;
}

- (void)touchTile:(RMTile)tile withKey:(NSString *)cacheKey
{
    [_writeQueue addOperationWithBlock:^{
      [self->_writeQueueLock lock];

      [self->_queue inDatabase:^(FMDatabase *db)
         {
             BOOL result = [db executeUpdate:@"UPDATE ZCACHE SET last_used = ? WHERE tile_hash = ? AND cache_key = ?", [NSDate date], [RMTileCache tileHash:tile], cacheKey];

             if (result == NO)
                 RMLog(@"Error touching tile");
         }];

      [self->_writeQueueLock unlock];
    }];
}

- (void)didReceiveMemoryWarning
{
    RMLog(@"Low memory in the database tilecache");

    [_writeQueueLock lock];
    [_writeQueue cancelAllOperations];
    [_writeQueueLock unlock];
}

@end
