//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "OWSBackupJob.h"
#import "OWSBackupIO.h"
#import "Signal-Swift.h"
#import <Curve25519Kit/Randomness.h>
#import <SAMKeychain/SAMKeychain.h>
#import <YapDatabase/YapDatabaseCryptoUtils.h>

NS_ASSUME_NONNULL_BEGIN

NSString *const kOWSBackup_ManifestKey_DatabaseFiles = @"database_files";
NSString *const kOWSBackup_ManifestKey_AttachmentFiles = @"attachment_files";
NSString *const kOWSBackup_ManifestKey_RecordName = @"record_name";
NSString *const kOWSBackup_ManifestKey_EncryptionKey = @"encryption_key";
NSString *const kOWSBackup_ManifestKey_RelativeFilePath = @"relative_file_path";
NSString *const kOWSBackup_ManifestKey_DataSize = @"data_size";

NSString *const kOWSBackup_KeychainService = @"kOWSBackup_KeychainService";

@implementation OWSBackupManifestItem

@end

#pragma mark -

@implementation OWSBackupManifestContents

@end

#pragma mark -

@interface OWSBackupJob ()

@property (nonatomic, weak) id<OWSBackupJobDelegate> delegate;

@property (atomic) BOOL isComplete;
@property (atomic) BOOL hasSucceeded;

@property (nonatomic) OWSPrimaryStorage *primaryStorage;

@property (nonatomic) NSString *jobTempDirPath;

@end

#pragma mark -

@implementation OWSBackupJob

- (instancetype)initWithDelegate:(id<OWSBackupJobDelegate>)delegate primaryStorage:(OWSPrimaryStorage *)primaryStorage
{
    self = [super init];

    if (!self) {
        return self;
    }

    OWSAssert(primaryStorage);
    OWSAssert([OWSStorage isStorageReady]);

    self.delegate = delegate;
    self.primaryStorage = primaryStorage;

    return self;
}

- (void)dealloc
{
    // Surface memory leaks by logging the deallocation.
    DDLogVerbose(@"Dealloc: %@", self.class);

    [[NSNotificationCenter defaultCenter] removeObserver:self];

    if (self.jobTempDirPath) {
        [OWSFileSystem deleteFileIfExists:self.jobTempDirPath];
    }
}

- (BOOL)ensureJobTempDir
{
    DDLogVerbose(@"%@ %s", self.logTag, __PRETTY_FUNCTION__);

    // TODO: Exports should use a new directory each time, but imports
    // might want to use a predictable directory so that repeated
    // import attempts can reuse downloads from previous attempts.
    NSString *temporaryDirectory = NSTemporaryDirectory();
    self.jobTempDirPath = [temporaryDirectory stringByAppendingString:[NSUUID UUID].UUIDString];

    if (![OWSFileSystem ensureDirectoryExists:self.jobTempDirPath]) {
        OWSProdLogAndFail(@"%@ Could not create jobTempDirPath.", self.logTag);
        return NO;
    }
    if (![OWSFileSystem protectFileOrFolderAtPath:self.jobTempDirPath]) {
        OWSProdLogAndFail(@"%@ Could not protect jobTempDirPath.", self.logTag);
        return NO;
    }
    return YES;
}

#pragma mark -

- (void)cancel
{
    OWSAssertIsOnMainThread();

    self.isComplete = YES;
}

- (void)succeed
{
    DDLogInfo(@"%@ %s", self.logTag, __PRETTY_FUNCTION__);

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.isComplete) {
            OWSAssert(!self.hasSucceeded);
            return;
        }
        self.isComplete = YES;

        // There's a lot of asynchrony in these backup jobs;
        // ensure we only end up finishing these jobs once.
        OWSAssert(!self.hasSucceeded);
        self.hasSucceeded = YES;

        [self.delegate backupJobDidSucceed:self];
    });
}

- (void)failWithErrorDescription:(NSString *)description
{
    [self failWithError:OWSErrorWithCodeDescription(OWSErrorCodeImportBackupFailed, description)];
}

- (void)failWithError:(NSError *)error
{
    OWSProdLogAndFail(@"%@ %s %@", self.logTag, __PRETTY_FUNCTION__, error);

    dispatch_async(dispatch_get_main_queue(), ^{
        OWSAssert(!self.hasSucceeded);
        if (self.isComplete) {
            return;
        }
        self.isComplete = YES;
        [self.delegate backupJobDidFail:self error:error];
    });
}

- (void)updateProgressWithDescription:(nullable NSString *)description progress:(nullable NSNumber *)progress
{
    DDLogInfo(@"%@ %s", self.logTag, __PRETTY_FUNCTION__);

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.isComplete) {
            return;
        }
        [self.delegate backupJobDidUpdate:self description:description progress:progress];
    });
}

#pragma mark - Manifest

- (void)downloadAndProcessManifestWithSuccess:(OWSBackupJobManifestSuccess)success
                                      failure:(OWSBackupJobManifestFailure)failure
                                     backupIO:(OWSBackupIO *)backupIO
{
    OWSAssert(success);
    OWSAssert(failure);
    OWSAssert(backupIO);

    DDLogVerbose(@"%@ %s", self.logTag, __PRETTY_FUNCTION__);

    __weak OWSBackupJob *weakSelf = self;
    [OWSBackupAPI downloadManifestFromCloudWithSuccess:^(NSData *data) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [weakSelf processManifest:data
                              success:success
                              failure:^{
                                  failure(OWSErrorWithCodeDescription(OWSErrorCodeImportBackupFailed,
                                      NSLocalizedString(@"BACKUP_IMPORT_ERROR_COULD_NOT_IMPORT",
                                          @"Error indicating the a backup import could not import the user's data.")));
                              }
                             backupIO:backupIO];
        });
    }
        failure:^(NSError *error) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                // The manifest file is critical so any error downloading it is unrecoverable.
                OWSProdLogAndFail(@"%@ Could not download manifest.", weakSelf.logTag);
                failure(error);
            });
        }];
}

- (void)processManifest:(NSData *)manifestDataEncrypted
                success:(OWSBackupJobManifestSuccess)success
                failure:(dispatch_block_t)failure
               backupIO:(OWSBackupIO *)backupIO
{
    OWSAssert(manifestDataEncrypted.length > 0);
    OWSAssert(success);
    OWSAssert(failure);
    OWSAssert(backupIO);

    if (self.isComplete) {
        return;
    }

    DDLogVerbose(@"%@ %s", self.logTag, __PRETTY_FUNCTION__);

    NSData *_Nullable manifestDataDecrypted =
        [backupIO decryptDataAsData:manifestDataEncrypted encryptionKey:self.delegate.backupEncryptionKey];
    if (!manifestDataDecrypted) {
        OWSProdLogAndFail(@"%@ Could not decrypt manifest.", self.logTag);
        return failure();
    }

    NSError *error;
    NSDictionary<NSString *, id> *_Nullable json =
        [NSJSONSerialization JSONObjectWithData:manifestDataDecrypted options:0 error:&error];
    if (![json isKindOfClass:[NSDictionary class]]) {
        OWSProdLogAndFail(@"%@ Could not download manifest.", self.logTag);
        return failure();
    }

    DDLogVerbose(@"%@ json: %@", self.logTag, json);

    NSArray<OWSBackupManifestItem *> *_Nullable databaseItems =
        [self parseItems:json key:kOWSBackup_ManifestKey_DatabaseFiles];
    if (!databaseItems) {
        return failure();
    }
    NSArray<OWSBackupManifestItem *> *_Nullable attachmentsItems =
        [self parseItems:json key:kOWSBackup_ManifestKey_AttachmentFiles];
    if (!attachmentsItems) {
        return failure();
    }

    OWSBackupManifestContents *contents = [OWSBackupManifestContents new];
    contents.databaseItems = databaseItems;
    contents.attachmentsItems = attachmentsItems;

    return success(contents);
}

- (nullable NSArray<OWSBackupManifestItem *> *)parseItems:(id)json key:(NSString *)key
{
    OWSAssert(json);
    OWSAssert(key.length);

    if (![json isKindOfClass:[NSDictionary class]]) {
        OWSProdLogAndFail(@"%@ manifest has invalid data: %@.", self.logTag, key);
        return nil;
    }
    NSArray *itemMaps = json[key];
    if (![itemMaps isKindOfClass:[NSArray class]]) {
        OWSProdLogAndFail(@"%@ manifest has invalid data: %@.", self.logTag, key);
        return nil;
    }
    NSMutableArray<OWSBackupManifestItem *> *items = [NSMutableArray new];
    for (NSDictionary *itemMap in itemMaps) {
        if (![itemMap isKindOfClass:[NSDictionary class]]) {
            OWSProdLogAndFail(@"%@ manifest has invalid item: %@.", self.logTag, key);
            return nil;
        }
        NSString *_Nullable recordName = itemMap[kOWSBackup_ManifestKey_RecordName];
        NSString *_Nullable encryptionKeyString = itemMap[kOWSBackup_ManifestKey_EncryptionKey];
        NSString *_Nullable relativeFilePath = itemMap[kOWSBackup_ManifestKey_RelativeFilePath];
        NSNumber *_Nullable uncompressedDataLength = itemMap[kOWSBackup_ManifestKey_DataSize];
        if (![recordName isKindOfClass:[NSString class]]) {
            OWSProdLogAndFail(@"%@ manifest has invalid recordName: %@.", self.logTag, key);
            return nil;
        }
        if (![encryptionKeyString isKindOfClass:[NSString class]]) {
            OWSProdLogAndFail(@"%@ manifest has invalid encryptionKey: %@.", self.logTag, key);
            return nil;
        }
        // relativeFilePath is an optional field.
        if (relativeFilePath && ![relativeFilePath isKindOfClass:[NSString class]]) {
            OWSProdLogAndFail(@"%@ manifest has invalid relativeFilePath: %@.", self.logTag, key);
            return nil;
        }
        NSData *_Nullable encryptionKey = [NSData dataFromBase64String:encryptionKeyString];
        if (!encryptionKey) {
            OWSProdLogAndFail(@"%@ manifest has corrupt encryptionKey: %@.", self.logTag, key);
            return nil;
        }
        // uncompressedDataLength is an optional field.
        if (uncompressedDataLength && ![uncompressedDataLength isKindOfClass:[NSNumber class]]) {
            OWSProdLogAndFail(@"%@ manifest has invalid uncompressedDataLength: %@.", self.logTag, key);
            return nil;
        }

        OWSBackupManifestItem *item = [OWSBackupManifestItem new];
        item.recordName = recordName;
        item.encryptionKey = encryptionKey;
        item.relativeFilePath = relativeFilePath;
        item.uncompressedDataLength = uncompressedDataLength;
        [items addObject:item];
    }
    return items;
}

@end

NS_ASSUME_NONNULL_END
