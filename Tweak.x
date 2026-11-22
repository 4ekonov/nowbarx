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

static BOOL NBShouldHideBar(void);

static void NBEnsureBar(UIViewController *vc) {
    UIView *host = vc.view;
    if (!host) return;
    gHost = host;
    if (!gBar) {
        gBar = [[NBBarView alloc] initWithFrame:host.bounds];
        gBar.suppressProbe = ^BOOL{ return NBShouldHideBar(); };
    }
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
    NSString *extra = @"";
    if ([v isKindOfClass:[UIScrollView class]]) {
        UIScrollView *sv = (UIScrollView *)v;
        extra = [NSString stringWithFormat:@" SCROLL offset=%@ size=%@ inset=%@", NSStringFromCGPoint(sv.contentOffset), NSStringFromCGSize(sv.contentSize), NSStringFromUIEdgeInsets(sv.adjustedContentInset)];
    }
    [out appendFormat:@"%@%@ alpha=%.2f hidden=%d frame=%@%@\n",
        [@"" stringByPaddingToLength:(NSUInteger)depth * 2 withString:@" " startingAtIndex:0],
        NSStringFromClass([v class]), v.alpha, v.hidden, NSStringFromCGRect(v.frame), extra];
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

#pragma mark - Menus, search, notification history, passcode, keyboard

static BOOL gKeyboardUp;
static BOOL gPasscodeCached;
static NSHashTable<UIView *> *gMenuViews;       // "Today" / search pages (slide in from the side)
static NSHashTable<UIScrollView *> *gNotifScrolls;
static CFAbsoluteTime gLastScan;
static NSString *gReason;

static CGFloat NBEffectiveAlpha(UIView *v) {
    CGFloat a = 1;
    for (UIView *x = v; x; x = x.superview) {
        if (x.hidden) return 0;
        a *= x.alpha;
    }
    return a;
}

// Fraction of the lock screen covered by this view (0 when it is off screen, hidden or transparent).
static CGFloat NBCoverage(UIView *v, UIView *host) {
    if (v.hidden || !v.window || NBEffectiveAlpha(v) < 0.3) return 0;
    CGRect r = [host convertRect:v.bounds fromView:v];
    CGRect i = CGRectIntersection(r, host.bounds);
    if (CGRectIsNull(i)) return 0;
    CGFloat area = host.bounds.size.width * host.bounds.size.height;
    return area > 0 ? (i.size.width * i.size.height) / area : 0;
}

static void NBCollect(UIView *root, UIView *host, int depth, BOOL *passcode) {
    if (depth > 14) return;
    for (UIView *v in root.subviews) {
        if (v == gBar) continue;
        NSString *n = NSStringFromClass([v class]);
        if ([n containsString:@"Passcode"] && NBCoverage(v, host) > 0.25) *passcode = YES;
        if ([n containsString:@"Today"] || [n containsString:@"Spotlight"] || [n containsString:@"Search"] || [n hasPrefix:@"SPUI"]) {
            [gMenuViews addObject:v];
        }
        if ([v isKindOfClass:[UIScrollView class]] && [n containsString:@"Notification"]) {
            [gNotifScrolls addObject:(UIScrollView *)v];
        }
        NBCollect(v, host, depth + 1, passcode);
    }
}

static BOOL NBShouldHideBar(void) {
    UIView *host = gHost;
    if (!host || !host.window) return NO;

    // the tree is walked a few times per second, the cached views are checked on every call
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - gLastScan > 0.25) {
        gLastScan = now;
        [gMenuViews removeAllObjects];
        [gNotifScrolls removeAllObjects];
        BOOL pc = NO;
        NBCollect(host, host, 0, &pc);
        gPasscodeCached = pc;
    }

    NSString *reason = nil;
    if (gKeyboardUp) reason = @"keyboard";
    else if (gPasscodeCached) reason = @"passcode";
    if (!reason) {
        for (UIView *v in gMenuViews.allObjects) {
            // page views (today / search) slide in from the side; a large visible part means a menu is open
            if (NBCoverage(v, host) > 0.12) { reason = [@"menu:" stringByAppendingString:NSStringFromClass([v class])]; break; }
        }
    }
    if (!reason) {
        for (UIScrollView *sv in gNotifScrolls.allObjects) {
            if (sv.window && NBEffectiveAlpha(sv) > 0.3 && sv.contentOffset.y + sv.adjustedContentInset.top > 40) {
                reason = [@"notifications:" stringByAppendingString:NSStringFromClass([sv class])];
                break;
            }
        }
    }

#ifdef NB_DEBUG
    static NSString *lastReason;
    static int writes;
    if (!(reason == lastReason || [reason isEqualToString:lastReason]) && writes < 40) {
        lastReason = reason;
        writes++;
        NSString *path = @"/var/mobile/Documents/NowBarX-menus.txt";
        NSString *old = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
        NSString *line = [NSString stringWithFormat:@"%@ hide=%@\n", [NSDate date], reason ?: @"no"];
        [[old stringByAppendingString:line] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        if (reason && writes < 12) {   // full tree at the moment a menu is open, for diagnosis
            NSMutableString *out = [NSMutableString stringWithFormat:@"reason=%@ keyboard=%d\n", reason, gKeyboardUp];
            NBDumpTree(host, 0, out);
            NSString *tp = [NSString stringWithFormat:@"/var/mobile/Documents/NowBarX-tree-%d.txt", writes];
            [out writeToFile:tp atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    }
#endif
    gReason = reason;
    return reason != nil;
}

#pragma mark - Hooks

%hook CSCoverSheetViewController

- (void)viewDidLoad {
    %orig;
    NBEnsureBar(self);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    gKeyboardUp = NO;   // a keyboard that was up when the lock screen went away must not stick
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
    [gBar checkSuppressed];
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
        gMenuViews = [NSHashTable weakObjectsHashTable];
        gNotifScrolls = [NSHashTable weakObjectsHashTable];
        NSNotificationCenter *kc = [NSNotificationCenter defaultCenter];
        [kc addObserverForName:UIKeyboardWillShowNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) { gKeyboardUp = YES; }];
        [kc addObserverForName:UIKeyboardWillHideNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) { gKeyboardUp = NO; }];
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
