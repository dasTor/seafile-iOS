//
//  SeafGlobal.m
//  seafilePro
//
//  Created by Wang Wei on 11/9/14.
//  Copyright (c) 2014 Seafile. All rights reserved.
//
#import "SeafGlobal.h"
#import "SeafUploadFile.h"
#import "SeafDir.h"
#import "Utils.h"
#import "Debug.h"


@interface SeafGlobal()
@property (retain) NSMutableArray *ufiles;
@property (retain) NSMutableArray *dfiles;
@property (retain) NSMutableArray *uploadingfiles;
@property unsigned long downloadnum;
@property unsigned long failedNum;
@property NSUserDefaults *storage;

@property NSTimer *autoSyncTimer;

@end

@implementation SeafGlobal
@synthesize managedObjectContext = __managedObjectContext;
@synthesize managedObjectModel = __managedObjectModel;
@synthesize persistentStoreCoordinator = __persistentStoreCoordinator;

-(id)init
{
    if (self = [super init]) {
        _assetsLibrary = [[ALAssetsLibrary alloc] init];
        _ufiles = [[NSMutableArray alloc] init];
        _dfiles = [[NSMutableArray alloc] init];
        _uploadingfiles = [[NSMutableArray alloc] init];
        _conns = [[NSMutableArray alloc] init];
        _downloadnum = 0;
        _storage = [[NSUserDefaults alloc] initWithSuiteName:GROUP_NAME];
        [self checkSettings];
        Debug("applicationDocumentsDirectoryURL=%@",  self.applicationDocumentsDirectoryURL);
    }
    return self;
}

- (void)checkSettings
{
    NSUserDefaults * standardUserDefaults = [NSUserDefaults standardUserDefaults];
    id obj = [standardUserDefaults objectForKey:@"allow_invalid_cert"];
    if (!obj)
        [self registerDefaultsFromSettingsBundle];
}

- (void)loadSettings:(NSUserDefaults *)standardUserDefaults
{
    _allowInvalidCert = [standardUserDefaults boolForKey:@"allow_invalid_cert"];
}

- (void)defaultsChanged:(NSNotification *)notification
{
    NSUserDefaults *standardUserDefaults = (NSUserDefaults *)[notification object];
    [self loadSettings:standardUserDefaults];
}

+ (SeafGlobal *)sharedObject
{
    static SeafGlobal *object = nil;
    if (!object) {
        object = [[SeafGlobal alloc] init];
    }
    return object;
}

- (NSURL *)applicationDocumentsDirectoryURL
{
    return [[[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:GROUP_NAME] URLByAppendingPathComponent:@"seafile" isDirectory:true];
}

- (NSString *)applicationDocumentsDirectory
{
    return [[self applicationDocumentsDirectoryURL] path];
}

- (NSString *)uploadsDir
{
    return [self.applicationDocumentsDirectory stringByAppendingPathComponent:UPLOADS_DIR];
}

- (NSString *)avatarsDir
{
    return [self.applicationDocumentsDirectory stringByAppendingPathComponent:AVATARS_DIR];
}
- (NSString *)certsDir
{
    return [self.applicationDocumentsDirectory stringByAppendingPathComponent:CERTS_DIR];
}
- (NSString *)editDir
{
    return [self.applicationDocumentsDirectory stringByAppendingPathComponent:EDIT_DIR];
}
- (NSString *)thumbsDir
{
    return [self.applicationDocumentsDirectory stringByAppendingPathComponent:THUMB_DIR];
}
- (NSString *)objectsDir
{
    return [self.applicationDocumentsDirectory stringByAppendingPathComponent:OBJECTS_DIR];
}
- (NSString *)blocksDir
{
    return [self.applicationDocumentsDirectory stringByAppendingPathComponent:BLOCKS_DIR];
}
- (NSString *)tempDir
{
    return [[self applicationDocumentsDirectory] stringByAppendingPathComponent:TEMP_DIR];
}

- (NSString *)documentPath:(NSString*)fileId
{
    return[self.objectsDir stringByAppendingPathComponent:fileId];
}

- (NSString *)blockPath:(NSString*)blkId
{
    return [self.blocksDir stringByAppendingPathComponent:blkId];
}

- (void)registerDefaultsFromSettingsBundle
{
    Debug("Registering default values from Settings.bundle");
    NSUserDefaults * defs = [NSUserDefaults standardUserDefaults];
    [defs synchronize];

    NSString *settingsBundle = [[NSBundle mainBundle] pathForResource:@"Settings" ofType:@"bundle"];
    if(!settingsBundle) {
        Debug("Could not find Settings.bundle");
        return;
    }

    NSDictionary *settings = [NSDictionary dictionaryWithContentsOfFile:[settingsBundle stringByAppendingPathComponent:@"Root.plist"]];
    NSArray *preferences = [settings objectForKey:@"PreferenceSpecifiers"];
    NSMutableDictionary *defaultsToRegister = [[NSMutableDictionary alloc] initWithCapacity:[preferences count]];

    for (NSDictionary *prefSpecification in preferences) {
        NSString *key = [prefSpecification objectForKey:@"Key"];
        if (key) {
            // check if value readable in userDefaults
            id currentObject = [defs objectForKey:key];
            if (currentObject == nil) {
                // not readable: set value from Settings.bundle
                id objectToSet = [prefSpecification objectForKey:@"DefaultValue"];
                [defaultsToRegister setObject:objectToSet forKey:key];
                Debug("Setting object %@ for key %@", objectToSet, key);
            } else {
                // already readable: don't touch
                Debug("Key %@ is readable (value: %@), nothing written to defaults.", key, currentObject);
            }
        }
    }

    [defs registerDefaults:defaultsToRegister];
    [defs synchronize];
}

- (void)migrateUserDefaults
{
    NSUserDefaults *oldDef = [NSUserDefaults standardUserDefaults];
    NSUserDefaults *newDef = [[NSUserDefaults alloc] initWithSuiteName:GROUP_NAME];
    NSArray *accounts = [oldDef objectForKey:@"ACCOUNTS"];
    if (accounts && accounts.count > 0) {
        for(NSString *key in oldDef.dictionaryRepresentation) {
            [newDef setObject:[oldDef objectForKey:key] forKey:key];
        }
        [newDef synchronize];
        [oldDef removeObjectForKey:@"ACCOUNTS"];
        [oldDef synchronize];
    }
    Debug("accounts:%@\nnew:%@", oldDef.dictionaryRepresentation, newDef.dictionaryRepresentation);

}
- (void)migrateDocuments
{

    NSURL *oldURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
    NSURL *newURL = [[[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:GROUP_NAME] URLByAppendingPathComponent:@"seafile" isDirectory:true];
    if ([Utils fileExistsAtPath:newURL.path])
        return;

    [Utils checkMakeDir:newURL.path];

    if (!newURL) return;

    NSFileManager* manager = [NSFileManager defaultManager];
    NSEnumerator *childFilesEnumerator = [[manager subpathsAtPath:oldURL.path] objectEnumerator];
    NSString* fileName;
    while ((fileName = [childFilesEnumerator nextObject]) != nil){
        NSError *error = nil;
        NSString* src = [oldURL.path stringByAppendingPathComponent:fileName];
        NSString* dest = [newURL.path stringByAppendingPathComponent:fileName];
        if ([Utils fileExistsAtPath:dest]) continue;
        [[NSFileManager defaultManager] moveItemAtPath:src toPath:dest error:&error];
        if (error) {
            Warning("migrate data error=%@", error);
        }
    }
}
- (void)migrate
{
    [self migrateUserDefaults];
    [self migrateDocuments];
}

- (void)saveAccounts
{
    NSMutableArray *accounts = [[NSMutableArray alloc] init];
    for (SeafConnection *connection in self.conns) {
        NSMutableDictionary *account = [[NSMutableDictionary alloc] init];
        [account setObject:connection.address forKey:@"url"];
        [account setObject:connection.username forKey:@"username"];
        [accounts addObject:account];
    }
    Debug("accounts:%@", accounts);
    [self setObject:accounts forKey:@"ACCOUNTS"];
};

- (void)loadAccounts
{
    NSUserDefaults * standardUserDefaults = [NSUserDefaults standardUserDefaults];
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self
               selector:@selector(defaultsChanged:)
                   name:NSUserDefaultsDidChangeNotification
                 object:standardUserDefaults];
    [self loadSettings:standardUserDefaults];
    Debug("allowInvalidCert=%d", _allowInvalidCert);

    NSMutableArray *connections = [[NSMutableArray alloc] init];
    NSArray *accounts = [self objectForKey:@"ACCOUNTS"];
    Debug("accounts:%@", accounts);
    for (NSDictionary *account in accounts) {
        SeafConnection *conn = [[SeafConnection alloc] initWithUrl:[account objectForKey:@"url"] username:[account objectForKey:@"username"]];
        if (conn.username)
            [connections addObject:conn];
    }
    self.conns = connections;
}

- (SeafConnection *)getConnection:(NSString *)url username:(NSString *)username
{
    SeafConnection *conn;
    if ([url hasSuffix:@"/"])
        url = [url substringToIndex:url.length-1];
    for (conn in self.conns) {
        if ([conn.address isEqual:url] && [conn.username isEqual:username])
            return conn;
    }
    return nil;
}

#pragma mark - Core Data stack

// Returns the managed object context for the application.
// If the context doesn't already exist, it is created and bound to the persistent store coordinator for the application.
- (NSManagedObjectContext *)managedObjectContext
{
    if (__managedObjectContext != nil) {
        return __managedObjectContext;
    }

    NSPersistentStoreCoordinator *coordinator = [self persistentStoreCoordinator];
    if (coordinator != nil) {
        __managedObjectContext = [[NSManagedObjectContext alloc] init];
        [__managedObjectContext setPersistentStoreCoordinator:coordinator];
    }
    return __managedObjectContext;
}

// Returns the managed object model for the application.
// If the model doesn't already exist, it is created from the application's model.
- (NSManagedObjectModel *)managedObjectModel
{
    if (__managedObjectModel != nil) {
        return __managedObjectModel;
    }
    NSURL *modelURL = [[NSBundle mainBundle] URLForResource:@"seafile" withExtension:@"momd"];
    __managedObjectModel = [[NSManagedObjectModel alloc] initWithContentsOfURL:modelURL];
    return __managedObjectModel;
}

// Returns the persistent store coordinator for the application.
// If the coordinator doesn't already exist, it is created and the application's store added to it.
- (NSPersistentStoreCoordinator *)persistentStoreCoordinator
{
    if (__persistentStoreCoordinator != nil) {
        return __persistentStoreCoordinator;
    }
    NSURL *storeURL = [[self applicationDocumentsDirectoryURL] URLByAppendingPathComponent:@"seafile_pro.sqlite"];

    NSError *error = nil;
    __persistentStoreCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:[self managedObjectModel]];
    if (![__persistentStoreCoordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:storeURL options:nil error:&error]) {
        /*
         Replace this implementation with code to handle the error appropriately.

         abort() causes the application to generate a crash log and terminate. You should not use this function in a shipping application, although it may be useful during development.

         Typical reasons for an error here include:
         * The persistent store is not accessible;
         * The schema for the persistent store is incompatible with current managed object model.
         Check the error message to determine what the actual problem was.


         If the persistent store is not accessible, there is typically something wrong with the file path. Often, a file URL is pointing into the application's resources directory instead of a writeable directory.

         If you encounter schema incompatibility errors during development, you can reduce their frequency by:
         * Simply deleting the existing store:
         [[NSFileManager defaultManager] removeItemAtURL:storeURL error:nil]

         * Performing automatic lightweight migration by passing the following dictionary as the options parameter:
         [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithBool:YES], NSMigratePersistentStoresAutomaticallyOption, [NSNumber numberWithBool:YES], NSInferMappingModelAutomaticallyOption, nil];

         Lightweight migration will only work for a limited set of schema changes; consult "Core Data Model Versioning and Data Migration Programming Guide" for details.

         */
        [[NSFileManager defaultManager] removeItemAtURL:storeURL error:nil];

        if (![__persistentStoreCoordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:storeURL options:nil error:&error]) {
            NSLog(@"Unresolved error %@, %@", error, [error userInfo]);
            abort();
        }
    }

    return __persistentStoreCoordinator;
}

- (void)saveContext
{
    NSError *error = nil;
    NSManagedObjectContext *managedObjectContext = self.managedObjectContext;
    if (managedObjectContext != nil) {
        if ([managedObjectContext hasChanges] && ![managedObjectContext save:&error]) {
            // Replace this implementation with code to handle the error appropriately.
            // abort() causes the application to generate a crash log and terminate. You should not use this function in a shipping application, although it may be useful during development.
            NSLog(@"Unresolved error %@, %@", error, [error userInfo]);
            abort();
        }
    }
}


- (void)deleteAllObjects:(NSString *)entityDescription
{
    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] init];
    NSEntityDescription *entity = [NSEntityDescription entityForName:entityDescription inManagedObjectContext:__managedObjectContext];
    [fetchRequest setEntity:entity];

    NSError *error = nil;
    NSArray *items = [__managedObjectContext executeFetchRequest:fetchRequest error:&error];

    for (NSManagedObject *managedObject in items) {
        [__managedObjectContext deleteObject:managedObject];
    }
    if (![__managedObjectContext save:&error]) {
        Debug(@"Error deleting %@ - error:%@",entityDescription,error);
    }
}

- (void)incDownloadnum
{
    @synchronized (self) {
        _downloadnum ++;
    }
}
- (void)decDownloadnum
{
    @synchronized (self) {
        _downloadnum --;
    }
}

- (unsigned long)uploadingnum
{
    return self.uploadingfiles.count + self.ufiles.count;
}

- (unsigned long)downloadingnum
{
    return self.downloadnum + self.dfiles.count;
}

- (void)finishDownload:(id<SeafDownloadDelegate>) file result:(BOOL)result
{
    Debug("download %ld, result=%d, failcnt=%ld", self.downloadnum, result, self.failedNum);
    @synchronized (self) {
        self.downloadnum --;
    }

    if (result) {
        self.failedNum = 0;
    } else {
        self.failedNum ++;
        [self.dfiles addObject:file];
        if (self.failedNum >= 3) {
            [self performSelector:@selector(tryDownload) withObject:nil afterDelay:10.0];
            self.failedNum = 2;
            return;
        }
    }
    [self performSelector:@selector(tick:) withObject:_autoSyncTimer afterDelay:0.1];
}

- (void)finishUpload:(SeafUploadFile *)file result:(BOOL)result
{
    Debug("upload %ld, result=%d, file=%@, udir=%@", (long)self.uploadingfiles.count, result, file.lpath, file.udir.path);
    @synchronized (self) {
        [self.uploadingfiles removeObject:file];
    }

    if (result) {
        self.failedNum = 0;
        if (file.autoSync) {
            [file.udir->connection fileUploadedSuccess:file];
        }
    } else {
        self.failedNum ++;
        [self.ufiles addObject:file];
        if (self.failedNum >= 3) {
            [self performSelector:@selector(tryUpload) withObject:nil afterDelay:10.0];
            self.failedNum = 2;
            return;
        }
    }
    [self performSelector:@selector(tick:) withObject:_autoSyncTimer afterDelay:0.1];
}

- (void)tryUpload
{
    Debug("tryUpload uploading:%ld left:%ld", (long)self.uploadingfiles.count, (long)self.ufiles.count);
    if (self.ufiles.count == 0) return;
    NSMutableArray *todo = [[NSMutableArray alloc] init];
    @synchronized (self) {
        NSMutableArray *arr = [self.ufiles mutableCopy];
        for (SeafUploadFile *file in arr) {
            if (self.uploadingfiles.count + todo.count + self.failedNum >= 3) break;
            if (!file.canUpload) continue;
            [self.ufiles removeObject:file];
            if (!file.uploaded) {
                [todo addObject:file];
            }
        }
    }
    for (SeafUploadFile *file in todo) {
        if (!file.udir) continue;

        [file doUpload];
        @synchronized (self) {
            [self.uploadingfiles addObject:file];
        }
    }
}

- (void)tryDownload
{
    if (self.dfiles.count == 0) return;
    NSMutableArray *todo = [[NSMutableArray alloc] init];
    @synchronized (self) {
        NSMutableArray *arr = [self.dfiles mutableCopy];
        for (id<SeafDownloadDelegate> file in arr) {
            if (self.downloadnum + todo.count + self.failedNum >= 3) break;
            [self.dfiles removeObject:file];
            [todo addObject:file];
        }
    }
    for (id<SeafDownloadDelegate> file in todo) {
        [file download];
    }
}

- (void)removeBackgroundUpload:(SeafUploadFile *)file
{
    @synchronized (self) {
        [self.ufiles removeObject:file];
        [self.uploadingfiles removeObject:file];
    }
}

- (void)removeBackgroundDownload:(id<SeafDownloadDelegate>)file
{
    @synchronized (self) {
        [self.dfiles removeObject:file];
    }
}

- (void)clearAutoSyncPhotos:(SeafConnection *)conn
{
    NSMutableArray *arr = [[NSMutableArray alloc] init];
    @synchronized (self) {
        for (SeafUploadFile *ufile in _ufiles) {
            if (ufile.autoSync && ufile.udir->connection == conn) {
                [arr addObject:ufile];
            }
        }
        for (SeafUploadFile *ufile in _uploadingfiles) {
            if (ufile.autoSync && ufile.udir->connection == conn) {
                [arr addObject:ufile];
            }
        }
    }
    for (SeafUploadFile *ufile in arr) {
        [ufile.udir removeUploadFile:ufile];
    }
}

- (void)clearAutoSyncVideos:(SeafConnection *)conn
{
    NSMutableArray *arr = [[NSMutableArray alloc] init];
    @synchronized (self) {
        for (SeafUploadFile *ufile in _ufiles) {
            if (ufile.autoSync && ufile.udir->connection == conn && !ufile.isImageFile) {
                [arr addObject:ufile];
            }
        }
        for (SeafUploadFile *ufile in _uploadingfiles) {
            if (ufile.autoSync && ufile.udir->connection == conn && !ufile.isImageFile) {
                [arr addObject:ufile];
            }
        }
    }
    for (SeafUploadFile *ufile in arr) {
        [ufile.udir removeUploadFile:ufile];
    }
}

- (void)addUploadTask:(SeafUploadFile *)file
{
    @synchronized (self) {
        if (![_ufiles containsObject:file] && ![_uploadingfiles containsObject:file])
            [_ufiles addObject:file];
        else
            Debug("upload task file %@ already exist", file.name);
    }
    [self tryUpload];
}
- (void)addDownloadTask:(id<SeafDownloadDelegate>)file
{
    @synchronized (self) {
        if (![_dfiles containsObject:file])
            [_dfiles addObject:file];
    }
    [self tryDownload];
}

- (void)tick:(NSTimer *)timer
{
#define UPDATE_INTERVAL 180
    static double lastUpdate = 0;
    if (![[AFNetworkReachabilityManager sharedManager] isReachable]) {
        return;
    }
    @synchronized(timer) {
        for (SeafConnection *conn in self.conns) {
            [conn pickPhotosForUpload];

        }
        double cur = [[NSDate date] timeIntervalSince1970];
        if (cur - lastUpdate > UPDATE_INTERVAL) {
            Debug("%fs has passed, refreshRepoPassowrds", cur - lastUpdate);
            lastUpdate = cur;
            for (SeafConnection *conn in self.conns)
                [conn refreshRepoPassowrds];
        }
        if (self.ufiles.count > 0)
            [self tryUpload];
        if (self.dfiles.count > 0)
            [self tryDownload];
    }
}

- (void)startTimer
{
    Debug("Start timer.");
    [self tick:nil];
    _autoSyncTimer = [NSTimer scheduledTimerWithTimeInterval:5*60
                                                      target:self
                                                    selector:@selector(tick:)
                                                    userInfo:nil
                                                     repeats:YES];
    [[AFNetworkReachabilityManager sharedManager] setReachabilityStatusChangeBlock:^(AFNetworkReachabilityStatus status) {
        [self tick:_autoSyncTimer];
    }];
}

- (void)setObject:(id)value forKey:(NSString *)defaultName
{
    [_storage setObject:value forKey:defaultName];
}

- (id)objectForKey:(NSString *)defaultName
{
    return [_storage objectForKey:defaultName];
}

- (void)removeObjectForKey:(NSString *)defaultName
{
    [_storage removeObjectForKey:defaultName];
}

- (BOOL)synchronize
{
    return [_storage synchronize];
}

- (void)assetForURL:(NSURL *)assetURL resultBlock:(ALAssetsLibraryAssetForURLResultBlock)resultBlock failureBlock:(ALAssetsLibraryAccessFailureBlock)failureBlock
{
    [self.assetsLibrary assetForURL:assetURL
                        resultBlock:^(ALAsset *asset) {
                            // Success #1
                            if (asset){
                                resultBlock(asset);

                                // No luck, try another way
                            } else {
                                // Search in the Photo Stream Album
                                [self.assetsLibrary enumerateGroupsWithTypes:ALAssetsGroupPhotoStream
                                                                  usingBlock:^(ALAssetsGroup *group, BOOL *stop) {
                                     [group enumerateAssetsWithOptions:NSEnumerationReverse usingBlock:^(ALAsset *result, NSUInteger index, BOOL *stop) {
                                         if([result.defaultRepresentation.url isEqual:assetURL]) {
                                             resultBlock(result);
                                             *stop = YES;
                                         }
                                     }];
                                 }
                                                                failureBlock:^(NSError *error) {
                                                                    failureBlock(error);
                                                                }];
                            }

                        } failureBlock:^(NSError *error) {
                            failureBlock(error);
                        }];
}

- (NSComparisonResult)compare:(id<SeafPreView>)obj1 with:(id<SeafPreView>)obj2
{
    NSString *key = [SeafGlobal.sharedObject objectForKey:@"SORT_KEY"];
    if ([@"MTIME" caseInsensitiveCompare:key] == NSOrderedSame) {
        return [[NSNumber numberWithLongLong:obj1.mtime] compare:[NSNumber numberWithLongLong:obj2.mtime]];
    }
    return [obj1.name caseInsensitiveCompare:obj2.name];
}

@end
