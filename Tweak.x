#import <UIKit/UIKit.h>
#import "NBBarView.h"
#import "NBDataSource.h"
#import "NBSettings.h"
#import <objc/message.h>

@interface CSCoverSheetViewController : UIViewController
@end

static NBBarView *gBar;
static __weak UIView *gHost;
static NSHashTable<UIView *> *gHiddenMedia;
static NSHashTable<UIView *> *gHiddenHint;
static int gDumpCount;

static BOOL NBShouldHideBar(void);
static void NBUpdateStock(void);

static void NBEnsureBar(UIViewController *vc) {
    UIView *host = vc.view;
    if (!host) return;
    gHost = host;
    if (!gBar) {
        gBar = [[NBBarView alloc] initWithFrame:host.bounds];
        gBar.suppressProbe = ^BOOL{ return NBShouldHideBar(); };
        gBar.tickHook = ^{ NBUpdateStock(); };   // the system brings hidden views back from time to time
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

// The class names of the "Press Home to unlock" hint differ between iOS versions, so it is also found by its text.
static NSString *NBViewText(UIView *v) {
    if ([v isKindOfClass:[UILabel class]]) return ((UILabel *)v).text;
    if ([v respondsToSelector:NSSelectorFromString(@"string")]) {
        id s = ((id (*)(id, SEL))objc_msgSend)(v, NSSelectorFromString(@"string"));
        if ([s isKindOfClass:[NSString class]]) return s;
    }
    return nil;
}

static BOOL NBIsHintText(NSString *t) {
    if (!t.length || t.length > 90) return NO;
    NSString *l = t.lowercaseString;
    NSArray *needles = @[@"разблокир", @"«домой»", @"кнопку домой", @"чтобы открыть", @"press home", @"to unlock", @"to open", @"touch id", @"face id"];
    for (NSString *n in needles) if ([l containsString:n]) return YES;
    return NO;
}

static void NBScan(UIView *root, UIView *host, BOOL media, BOOL hint, int depth) {
    if (depth > 14) return;
    for (UIView *v in [root.subviews copy]) {
        if (v == gBar) continue;
        NSString *cn = NSStringFromClass([v class]);
        if (media && NBIsStockMedia(v)) {
            NBHideMediaWithBackground(v, host);
            continue;
        }
        if (hint && NBIsUnlockHint(v)) {
            NBHideView(v, gHiddenHint);
            continue;
        }
        BOOL hintHere = hint && ![cn containsString:@"Notification"];   // never touch notification text
        if (hintHere && ([cn containsString:@"Label"] || [cn containsString:@"Legibility"]) && NBIsHintText(NBViewText(v))) {
            NBHideView(v, gHiddenHint);
            continue;
        }
        NBScan(v, host, media, hintHere, depth + 1);
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

// Idea: the lock screen has a main page. Whatever pulls the screen away from it (search / "Today" page,
// camera page, notification history, keyboard, passcode) means the capsule must get out of the way.
// So instead of guessing class names, the scroll positions are compared with where they were at rest.

static BOOL gKeyboardUp;
static BOOL gPasscodeCached;
static NSHashTable<UIScrollView *> *gPageScrolls;    // horizontally paged scroll views (lock screen pages)
static NSHashTable<UIScrollView *> *gNotifScrolls;   // notification lists
static NSMapTable<UIScrollView *, NSValue *> *gBase; // resting content offset
static CFAbsoluteTime gLastScan;
static CFAbsoluteTime gBaselineUntil;                // right after the lock screen appears: learn the resting offsets
static NSString *gReason;

static CGFloat NBEffectiveAlpha(UIView *v) {
    CGFloat a = 1;
    for (UIView *x = v; x; x = x.superview) {
        if (x.hidden) return 0;
        a *= x.alpha;
    }
    return a;
}

static CGFloat NBCoverage(UIView *v, UIView *host) {
    if (v.hidden || !v.window || NBEffectiveAlpha(v) < 0.3) return 0;
    CGRect r = [host convertRect:v.bounds fromView:v];
    CGRect i = CGRectIntersection(r, host.bounds);
    if (CGRectIsNull(i)) return 0;
    CGFloat area = host.bounds.size.width * host.bounds.size.height;
    return area > 0 ? (i.size.width * i.size.height) / area : 0;
}

static void NBCollect(UIView *root, UIView *host, int depth, BOOL *passcode) {
    if (depth > 16) return;
    for (UIView *v in root.subviews) {
        if (v == gBar) continue;
        NSString *n = NSStringFromClass([v class]);
        if ([n containsString:@"Passcode"] && NBCoverage(v, host) > 0.25) *passcode = YES;
        if ([v isKindOfClass:[UIScrollView class]]) {
            UIScrollView *sv = (UIScrollView *)v;
            CGFloat w = sv.bounds.size.width;
            if (w >= host.bounds.size.width * 0.6 && sv.contentSize.width >= w * 1.6) [gPageScrolls addObject:sv];
            if ([n containsString:@"Notification"]) [gNotifScrolls addObject:sv];
        }
        NBCollect(v, host, depth + 1, passcode);
    }
}

static CGPoint NBBaseFor(UIScrollView *sv, BOOL learn) {
    NSValue *b = [gBase objectForKey:sv];
    if (!b || (learn && !sv.isDragging && !sv.isDecelerating)) {
        b = [NSValue valueWithCGPoint:sv.contentOffset];
        [gBase setObject:b forKey:sv];
    }
    return b.CGPointValue;
}

static BOOL NBKeyboardOnScreen(void) {
    if (gKeyboardUp) return YES;
    Class k = NSClassFromString(@"UIKeyboard");
    SEL s = NSSelectorFromString(@"isOnScreen");
    if (k && [k respondsToSelector:s]) return ((BOOL (*)(id, SEL))objc_msgSend)((id)k, s);
    return NO;
}

static BOOL NBShouldHideBar(void) {
    UIView *host = gHost;
    if (!host || !host.window) return NO;

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - gLastScan > 0.2) {
        gLastScan = now;
        [gPageScrolls removeAllObjects];
        [gNotifScrolls removeAllObjects];
        BOOL pc = NO;
        NBCollect(host, host, 0, &pc);
        gPasscodeCached = pc;
    }
    BOOL learning = now < gBaselineUntil;

    NSString *reason = nil;
    // the notification curtain / any slide of the whole lock screen: it is not sitting at its home position
    CALayer *pl = host.layer.presentationLayer ?: host.layer;
    CGPoint o = [pl convertPoint:CGPointZero toLayer:host.window.layer];
    if (fabs(o.x) > 4 || fabs(o.y) > 4) reason = [NSString stringWithFormat:@"moved %.0f,%.0f", o.x, o.y];
    else if (NBEffectiveAlpha(host) < 0.5) reason = @"faded";
    else if (NBKeyboardOnScreen()) reason = @"keyboard";
    else if (gPasscodeCached) reason = @"passcode";

    if (!reason) {
        for (UIScrollView *sv in gPageScrolls.allObjects) {
            CGPoint base = NBBaseFor(sv, learning);
            if (learning) continue;
            if (fabs(sv.contentOffset.x - base.x) > sv.bounds.size.width * 0.18) {
                reason = [NSString stringWithFormat:@"page:%@ off=%.0f base=%.0f", NSStringFromClass([sv class]), sv.contentOffset.x, base.x];
                break;
            }
        }
    }
    if (!reason) {
        for (UIScrollView *sv in gNotifScrolls.allObjects) {
            CGPoint base = NBBaseFor(sv, learning);
            if (learning) continue;
            if (sv.window && NBEffectiveAlpha(sv) > 0.3 && sv.contentOffset.y - base.y > 40) {
                reason = [NSString stringWithFormat:@"notifications:%@ off=%.0f base=%.0f", NSStringFromClass([sv class]), sv.contentOffset.y, base.y];
                break;
            }
        }
    }

#ifdef NB_DEBUG
    static NSString *lastKind;
    static int writes;
    NSString *kind = [[reason componentsSeparatedByString:@" "] firstObject];
    if (!(kind == lastKind || [kind isEqualToString:lastKind]) && writes < 60) {
        lastKind = kind;
        writes++;
        NSString *path = @"/var/mobile/Documents/NowBarX-menus.txt";
        NSString *old = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
        NSString *line = [NSString stringWithFormat:@"%@ hide=%@ pages=%lu notif=%lu\n", [NSDate date], reason ?: @"no", (unsigned long)gPageScrolls.count, (unsigned long)gNotifScrolls.count];
        [[old stringByAppendingString:line] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
#endif
    gReason = reason;
    return reason != nil;
}

#ifdef NB_DEBUG
// Every scroll view of the lock screen, to see what the pages are called if detection does not work.
static void NBDumpScrolls(UIView *v, int depth, NSMutableString *out) {
    if (depth > 16) return;
    if ([v isKindOfClass:[UIScrollView class]]) {
        UIScrollView *sv = (UIScrollView *)v;
        [out appendFormat:@"%@ bounds=%@ content=%@ offset=%@ inset=%@ paging=%d depth=%d\n", NSStringFromClass([v class]),
            NSStringFromCGSize(sv.bounds.size), NSStringFromCGSize(sv.contentSize), NSStringFromCGPoint(sv.contentOffset),
            NSStringFromUIEdgeInsets(sv.adjustedContentInset), sv.isPagingEnabled, depth];
    }
    for (UIView *s in v.subviews) NBDumpScrolls(s, depth + 1, out);
}
#endif

#pragma mark - Hooks

%hook CSCoverSheetViewController

- (void)viewDidLoad {
    %orig;
    NBEnsureBar(self);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    gKeyboardUp = NO;   // a keyboard that was up when the lock screen went away must not stick
    gBaselineUntil = CFAbsoluteTimeGetCurrent() + 1.2;   // learn the resting scroll positions
    NBEnsureBar(self);
    [gBar setActive:YES];
    NBUpdateStock();
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NBUpdateStock();
    NBMaybeDump();
#ifdef NB_DEBUG
    static int scrollDumps;
    if (scrollDumps < 3) {
        scrollDumps++;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *h = gHost;
            if (!h) return;
            NSMutableString *out = [NSMutableString string];
            NBDumpScrolls(h, 0, out);
            [out writeToFile:[NSString stringWithFormat:@"/var/mobile/Documents/NowBarX-scrolls-%d.txt", scrollDumps] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        });
    }
#endif
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
        gPageScrolls = [NSHashTable weakObjectsHashTable];
        gNotifScrolls = [NSHashTable weakObjectsHashTable];
        gBase = [NSMapTable weakToStrongObjectsMapTable];
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
