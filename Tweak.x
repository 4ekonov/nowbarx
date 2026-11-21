#import <UIKit/UIKit.h>
#import "NBBarView.h"
#import "NBDataSource.h"
#import "NBSettings.h"

@interface CSCoverSheetViewController : UIViewController
@end

static NBBarView *gBar;
static __weak UIView *gHost;
static NSHashTable<UIView *> *gHidden;
static int gDumpCount;

static void NBEnsureBar(UIViewController *vc) {
    UIView *host = vc.view;
    if (!host) return;
    gHost = host;
    if (!gBar) gBar = [[NBBarView alloc] initWithFrame:host.bounds];
    if (gBar.superview != host) {
        gBar.frame = host.bounds;
        [host addSubview:gBar];
    } else {
        [host bringSubviewToFront:gBar];
    }
}

#pragma mark - Stock lock screen player

// The stock lock screen player is found by class name, because the exact class differs between iOS 15, 16 and 17.
static BOOL NBIsStockMedia(UIView *v) {
    NSString *n = NSStringFromClass([v class]);
    return [n containsString:@"MediaControls"] || [n containsString:@"NowPlaying"] || [n hasPrefix:@"MRU"];
}

static void NBScan(UIView *root, int depth) {
    if (depth > 12) return;
    for (UIView *v in root.subviews) {
        if (v == gBar) continue;
        if (NBIsStockMedia(v)) {
            if (v.alpha != 0) v.alpha = 0;
            v.userInteractionEnabled = NO;
            [gHidden addObject:v];
            continue;
        }
        NBScan(v, depth + 1);
    }
}

static void NBRestoreStock(void) {
    for (UIView *v in gHidden.allObjects) {
        v.alpha = 1;
        v.userInteractionEnabled = YES;
    }
    [gHidden removeAllObjects];
}

static void NBUpdateStock(void) {
    UIView *host = gHost;
    if (!host) return;
    NBSettings *st = [NBSettings shared];
    BOOL hide = st.enabled && st.hideStockPlayer && [[NBDataSource shared] hasMedia];
    if (hide) NBScan(host, 0);
    else if (gHidden.count) NBRestoreStock();
}

#pragma mark - Debug: dump view tree

#ifdef NB_DEBUG
static void NBDumpTree(UIView *v, int depth, NSMutableString *out) {
    if (depth > 10) return;
    [out appendFormat:@"%@%@ alpha=%.2f hidden=%d frame=%@\n",
        [@"" stringByPaddingToLength:(NSUInteger)depth * 2 withString:@" " startingAtIndex:0],
        NSStringFromClass([v class]), v.alpha, v.hidden, NSStringFromCGRect(v.frame)];
    for (UIView *s in v.subviews) NBDumpTree(s, depth + 1, out);
}

static void NBMaybeDump(void) {
    UIView *host = gHost;
    if (!host || gDumpCount >= 3) return;
    if (![[NBDataSource shared] hasMedia]) return;
    gDumpCount++;
    NSMutableString *out = [NSMutableString string];
    NBDumpTree(host, 0, out);
    [out writeToFile:@"/var/mobile/Documents/NowBarX-views.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
#else
static void NBMaybeDump(void) {}
#endif

#pragma mark - Hooks

%hook CSCoverSheetViewController

- (void)viewDidLoad {
    %orig;
    NBEnsureBar(self);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    NBEnsureBar(self);
    [gBar setActive:YES];
    NBUpdateStock();
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NBUpdateStock();
    NBMaybeDump();
}

- (void)viewDidLayoutSubviews {
    %orig;
    NBEnsureBar(self);
    NBUpdateStock();
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    [gBar setActive:NO];
}

%end

%ctor {
    @autoreleasepool {
        gHidden = [NSHashTable weakObjectsHashTable];
        [NBSettings shared];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NBDataSource shared] start];
            NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
            [nc addObserverForName:NBItemsChangedNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
                NBUpdateStock();
                NBMaybeDump();
            }];
            [nc addObserverForName:NBSettingsChangedNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
                NBUpdateStock();
            }];
        });
    }
}
