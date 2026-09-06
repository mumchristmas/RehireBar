#import <AppKit/AppKit.h>
#import <Sparkle/Sparkle.h>

// An isolated disposable application for exercising the real Sparkle installer.
// It never reads Agent state or targets an installed RehireBar bundle.
@interface UpdateFixture : NSObject <NSApplicationDelegate, SPUUserDriver>
@property(nonatomic, strong) SPUUpdater *updater;
@property(nonatomic, strong) NSMutableArray<NSString *> *events;
@end

@implementation UpdateFixture
- (void)finish:(NSString *)kind error:(NSError *)error {
    NSMutableDictionary *result = [@{
        @"kind": kind,
        @"version": [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"],
        @"events": self.events ?: @[],
    } mutableCopy];
    if (error) {
        result[@"errorDomain"] = error.domain;
        result[@"errorCode"] = @(error.code);
        result[@"description"] = error.localizedDescription;
    }
    NSString *path = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"RBTestOutcome"];
    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:NULL];
    [data writeToFile:path options:NSDataWritingAtomic error:NULL];
    [NSApp terminate:nil];
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.events = [NSMutableArray new];
    if ([[[NSBundle mainBundle] objectForInfoDictionaryKey:@"RBTestReplacement"] boolValue]) {
        [self finish:@"installed-and-relaunched" error:nil];
        return;
    }
    self.updater = [[SPUUpdater alloc] initWithHostBundle:[NSBundle mainBundle]
                                      applicationBundle:[NSBundle mainBundle]
                                             userDriver:self delegate:nil];
    NSError *error = nil;
    if (![self.updater startUpdater:&error]) { [self finish:@"configuration-error" error:error]; return; }
    [self.updater checkForUpdates];
}
- (void)showUpdatePermissionRequest:(SPUUpdatePermissionRequest *)request reply:(void (^)(SUUpdatePermissionResponse *))reply {
    reply([[SUUpdatePermissionResponse alloc] initWithAutomaticUpdateChecks:NO sendSystemProfile:NO]);
}
- (void)showUserInitiatedUpdateCheckWithCancellation:(void (^)(void))cancellation { [self.events addObject:@"checking"]; }
- (void)showUpdateFoundWithAppcastItem:(SUAppcastItem *)item state:(SPUUserUpdateState *)state reply:(void (^)(SPUUserUpdateChoice))reply {
    [self.events addObject:@"found"];
    reply(SPUUserUpdateChoiceInstall);
}
- (void)showUpdateReleaseNotesWithDownloadData:(SPUDownloadData *)data {}
- (void)showUpdateReleaseNotesFailedToDownloadWithError:(NSError *)error {}
- (void)showUpdateNotFoundWithError:(NSError *)error acknowledgement:(void (^)(void))acknowledgement {
    acknowledgement(); [self finish:@"no-update" error:error];
}
- (void)showUpdaterError:(NSError *)error acknowledgement:(void (^)(void))acknowledgement {
    acknowledgement(); [self finish:@"rejected" error:error];
}
- (void)showDownloadInitiatedWithCancellation:(void (^)(void))cancellation { [self.events addObject:@"downloading"]; }
- (void)showDownloadDidReceiveExpectedContentLength:(uint64_t)length {}
- (void)showDownloadDidReceiveDataOfLength:(uint64_t)length {}
- (void)showDownloadDidStartExtractingUpdate { [self.events addObject:@"extracting"]; }
- (void)showExtractionReceivedProgress:(double)progress {}
- (void)showReadyToInstallAndRelaunch:(void (^)(SPUUserUpdateChoice))reply {
    [self.events addObject:@"installing"]; reply(SPUUserUpdateChoiceInstall);
}
- (void)showInstallingUpdateWithApplicationTerminated:(BOOL)terminated retryTerminatingApplication:(void (^)(void))retry {}
- (void)showUpdateInstalledAndRelaunched:(BOOL)relaunched acknowledgement:(void (^)(void))acknowledgement { acknowledgement(); }
- (void)dismissUpdateInstallation {}
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        static UpdateFixture *delegate;
        delegate = [UpdateFixture new];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return 0;
}
