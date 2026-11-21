#import <UIKit/UIKit.h>
#import "NBBarView.h"
#import "NBDataSource.h"
#import "NBSettings.h"

@interface CSCoverSheetViewController : UIViewController
@end

static NBBarView *gBar;
static __weak UIView *gHost;
static NSHashTable<UIView *> *gHiddenMedia;
static NSHashTable<UIView *> *gHiddenHint;
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

#pragma mark - Hiding stock lock screen elements

// The classes differ between iOS 15, 16 and 17, so they are found by name.
static BOOL NBIsStockMedia(UIView *v) {
    NSString *n = NSStringFromClass([v class]);
    return [n containsString:@"MediaControls"] || [n containsString:@"NowPlaying"] || [n hasPrefix:@"MRU"];
}

static BOOL NBIsUnlockHint(UIView *v) {
    NSString *n = NSStringFromClass([v class]);
    return [n containsString:@"TeachableMoments"] || [n containsString:@"CallToAction"];
}

static void NBHideView(UIView *v, NSHashTable<UIView *> *set) {
    if (v.alpha != 0) v.alpha = 0;
    v.userInteractionEnabled = NO;
    [set addObject:v];
}

// Hides the player and the container chain around it (its background panel lives in a parent view),
// but stops before anything that spans most of the screen or holds notifications.
static void NBHideMediaWithBackground(UIView *media, UIView *host) {
    NBHideView(media, gHiddenMedia);
    CGFloat hostArea = host.bounds.size.width * host.bounds.size.height;
    UIView *a = media.superview;
    int guard = 0;
    while (a && a != host && guard++ < 8) {
        NSString *n = NSStringFromClass([a class]);
        CGFloat area = a.bounds.size.width * a.bounds.size.height;
        if (area > hostArea * 0.55 || [n containsString:@"Notification"] || [n containsString:@"CoverSheet"] || [n containsString:@"ScrollView"]) break;
        NBHideView(a, gHiddenMedia);
        a = a.superview;
    }
}

static void NBScan(UIView *root, UIView *host, BOOL media, BOOL hint, int depth) {
    if (depth > 14) return;
    for (UIView *v in [root.subviews copy]) {
        if (v == gBar) continue;
        if (media && NBIsStockMedia(v)) {
            NBHideMediaWithBackground(v, host);
            continue;
        }
        if (hint && NBIsUnlockHint(v)) {
            NBHideView(v, gHiddenHint);
            continue;
        }
        NBScan(v, host, media, hint, depth + 1);
    }
}

static void NBRestore(NSHashTable<UIView *> *set) {
    for (UIView *v in set.allObjects) {
        v.alpha = 1;
        v.userInteractionEnabled = YES;
    }
    [set removeAllObjects];
}

static void NBUpdateStock(void) {
    UIView *host = gHost;
    if (!host) return;
    NBSettings *st = [NBSettings shared];
    BOOL hideMedia = st.enabled && st.hideStockPlayer && [[NBDataSource shared] hasMedia];
    BOOL hideHint = st.enabled && st.hideUnlockHint;
    if (!hideMedia && gHiddenMedia.count) NBRestore(gHiddenMedia);
    if (!hideHint && gHiddenHint.count) NBRestore(gHiddenHint);
    if (hideMedia || hideHint) NBScan(host, host, hideMedia, hideHint, 0);
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
        gHiddenMedia = [NSHashTable weakObjectsHashTable];
        gHiddenHint = [NSHashTable weakObjectsHashTable];
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
