//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "DebugUIBackup.h"
#import "OWSBackup.h"
#import "OWSTableViewController.h"
#import "Signal-Swift.h"
#import <Curve25519Kit/Randomness.h>

@import CloudKit;

NS_ASSUME_NONNULL_BEGIN

@implementation DebugUIBackup

#pragma mark - Factory Methods

- (NSString *)name
{
    return @"Backup";
}

- (nullable OWSTableSection *)sectionForThread:(nullable TSThread *)thread
{
    NSMutableArray<OWSTableItem *> *items = [NSMutableArray new];
    [items addObject:[OWSTableItem itemWithTitle:@"Backup test file to CloudKit"
                                     actionBlock:^{
                                         [DebugUIBackup backupTestFile];
                                     }]];
    [items addObject:[OWSTableItem itemWithTitle:@"Check for CloudKit backup"
                                     actionBlock:^{
                                         [DebugUIBackup checkForBackup];
                                     }]];
    [items addObject:[OWSTableItem itemWithTitle:@"Log CloudKit backup records"
                                     actionBlock:^{
                                         [DebugUIBackup logBackupRecords];
                                     }]];
    [items addObject:[OWSTableItem itemWithTitle:@"Restore CloudKit backup"
                                     actionBlock:^{
                                         [DebugUIBackup tryToImportBackup];
                                     }]];
    [items addObject:[OWSTableItem itemWithTitle:@"Log Database Size Stats"
                                     actionBlock:^{
                                         [DebugUIBackup logDatabaseSizeStats];
                                     }]];
    [items addObject:[OWSTableItem itemWithTitle:@"Clear All CloudKit Records"
                                     actionBlock:^{
                                         [DebugUIBackup clearAllCloudKitRecords];
                                     }]];

    return [OWSTableSection sectionWithTitle:self.name items:items];
}

+ (void)backupTestFile
{
    DDLogInfo(@"%@ backupTestFile.", self.logTag);

    NSData *_Nullable data = [Randomness generateRandomBytes:32];
    OWSAssert(data);
    NSString *filePath = [OWSFileSystem temporaryFilePathWithFileExtension:@"pdf"];
    BOOL success = [data writeToFile:filePath atomically:YES];
    OWSAssert(success);

    [OWSBackupAPI checkCloudKitAccessWithCompletion:^(BOOL hasAccess) {
        if (hasAccess) {
            [OWSBackupAPI saveTestFileToCloudWithFileUrl:[NSURL fileURLWithPath:filePath]
                                                 success:^(NSString *recordName) {
                                                     // Do nothing, the API method will log for us.
                                                 }
                                                 failure:^(NSError *error){
                                                     // Do nothing, the API method will log for us.
                                                 }];
        }
    }];
}

+ (void)checkForBackup
{
    DDLogInfo(@"%@ checkForBackup.", self.logTag);

    [OWSBackup.sharedManager checkCanImportBackup:^(BOOL value) {
        DDLogInfo(@"%@ has backup available  for import? %d", self.logTag, value);
    }
                                          failure:^(NSError *error){
                                              // Do nothing.
                                          }];
}

+ (void)logBackupRecords
{
    DDLogInfo(@"%@ logBackupRecords.", self.logTag);

    [OWSBackup.sharedManager logBackupRecords];
}

+ (void)tryToImportBackup
{
    DDLogInfo(@"%@ tryToImportBackup.", self.logTag);

    UIAlertController *controller =
        [UIAlertController alertControllerWithTitle:@"Restore CloudKit Backup"
                                            message:@"This will delete all of your database contents."
                                     preferredStyle:UIAlertControllerStyleAlert];

    [controller addAction:[UIAlertAction actionWithTitle:@"Restore"
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction *_Nonnull action) {
                                                     [OWSBackup.sharedManager tryToImportBackup];
                                                 }]];
    [controller addAction:[OWSAlerts cancelAction]];
    UIViewController *fromViewController = [[UIApplication sharedApplication] frontmostViewController];
    [fromViewController presentViewController:controller animated:YES completion:nil];
}

+ (void)logDatabaseSizeStats
{
    DDLogInfo(@"%@ logDatabaseSizeStats.", self.logTag);

    __block unsigned long long interactionCount = 0;
    __block unsigned long long interactionSizeTotal = 0;
    __block unsigned long long attachmentCount = 0;
    __block unsigned long long attachmentSizeTotal = 0;
    [[OWSPrimaryStorage.sharedManager newDatabaseConnection] readWithBlock:^(YapDatabaseReadTransaction *transaction) {
        [transaction enumerateKeysAndObjectsInCollection:[TSInteraction collection]
                                              usingBlock:^(NSString *key, id object, BOOL *stop) {
                                                  TSInteraction *interaction = object;
                                                  interactionCount++;
                                                  NSData *_Nullable data =
                                                      [NSKeyedArchiver archivedDataWithRootObject:interaction];
                                                  OWSAssert(data);
                                                  interactionSizeTotal += data.length;
                                              }];
        [transaction enumerateKeysAndObjectsInCollection:[TSAttachment collection]
                                              usingBlock:^(NSString *key, id object, BOOL *stop) {
                                                  TSAttachment *attachment = object;
                                                  attachmentCount++;
                                                  NSData *_Nullable data =
                                                      [NSKeyedArchiver archivedDataWithRootObject:attachment];
                                                  OWSAssert(data);
                                                  attachmentSizeTotal += data.length;
                                              }];
    }];

    DDLogInfo(@"%@ interactionCount: %llu", self.logTag, interactionCount);
    DDLogInfo(@"%@ interactionSizeTotal: %llu", self.logTag, interactionSizeTotal);
    if (interactionCount > 0) {
        DDLogInfo(@"%@ interaction average size: %f", self.logTag, interactionSizeTotal / (double)interactionCount);
    }
    DDLogInfo(@"%@ attachmentCount: %llu", self.logTag, attachmentCount);
    DDLogInfo(@"%@ attachmentSizeTotal: %llu", self.logTag, attachmentSizeTotal);
    if (attachmentCount > 0) {
        DDLogInfo(@"%@ attachment average size: %f", self.logTag, attachmentSizeTotal / (double)attachmentCount);
    }
}

+ (void)clearAllCloudKitRecords
{
    DDLogInfo(@"%@ clearAllCloudKitRecords.", self.logTag);

    [OWSBackup.sharedManager clearAllCloudKitRecords];
}

@end

NS_ASSUME_NONNULL_END
