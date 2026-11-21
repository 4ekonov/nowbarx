#import "NBDataSource.h"
#import "NBSettings.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

#ifdef NB_DEBUG
#define NBLog(fmt, ...) NSLog(@"[NowBarX] " fmt, ##__VA_ARGS__)
#else
#define NBLog(fmt, ...)
#endif

NSString *const NBItemsChangedNotification = @"NBItemsChangedNotification";

@implementation NBItem
@end

typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*MRGetBoolFn)(dispatch_queue_t, void (^)(Boolean));
typedef Boolean (*MRSendCmdFn)(int, CFDictionaryRef);
typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef void (*MRGetClientFn)(dispatch_queue_t, void (^)(CFTypeRef));
typedef CFStringRef (*MRClientBIDFn)(CFTypeRef);

#pragma mark - Runtime helpers

static id NBPerform(id obj, NSString *sel) {
    SEL s = NSSelectorFromString(sel);
    if (!obj || ![obj respondsToSelector:s]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(obj, s);
}

static id NBPerform1(id obj, NSString *sel, id arg) {
    SEL s = NSSelectorFromString(sel);
    if (!obj || ![obj respondsToSelector:s]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(obj, s, arg);
}

// MobileTimer managers often return an NAFuture; resolve it synchronously with a short timeout.
static id NBResolve(id v) {
    if (!v) return nil;
    SEL s1 = NSSelectorFromString(@"resultWithTimeout:error:");
    if ([v respondsToSelector:s1]) {
        NSError *err = nil;
        return ((id (*)(id, SEL, double, NSError **))objc_msgSend)(v, s1, 0.3, &err);
    }
    SEL s2 = NSSelectorFromString(@"resultWithError:");
    if ([v respondsToSelector:s2]) {
        NSError *err = nil;
        return ((id (*)(id, SEL, NSError **))objc_msgSend)(v, s2, &err);
    }
    return v;
}

static id NBVal(id obj, NSString *key) {
    @try { return [obj valueForKey:key]; }
    @catch (__unused NSException *e) { return nil; }
}

static NSDate *NBNextOccurrence(NSInteger hour, NSInteger minute) {
    NSCalendar *cal = [NSCalendar currentCalendar];
    return [cal nextDateAfterDate:[NSDate date]
                    matchingHour:hour
                          minute:minute
                          second:0
                         options:NSCalendarMatchNextTime];
}

// Dark, slightly vivid colour derived from the average colour of the artwork.
static UIColor *NBTintFromImage(UIImage *img) {
    if (!img.CGImage) return nil;
    unsigned char px[4] = {0, 0, 0, 0};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, 1, 1, 8, 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) return nil;
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, CGRectMake(0, 0, 1, 1), img.CGImage);
    CGContextRelease(ctx);
    UIColor *c = [UIColor colorWithRed:px[0] / 255.0 green:px[1] / 255.0 blue:px[2] / 255.0 alpha:1];
    CGFloat h = 0, s = 0, v = 0, a = 0;
    if (![c getHue:&h saturation:&s brightness:&v alpha:&a]) return nil;
    s = MIN(1.0, s * 1.15 + 0.05);
    v = MAX(0.18, MIN(0.38, v * 0.55));
    return [UIColor colorWithHue:h saturation:s brightness:v alpha:1];
}

static NSArray *NBFetchTimers(id mgr, NSMutableString *dbg) {
    for (NSString *sel in @[@"timersSync", @"timers"]) {
        id raw = NBPerform(mgr, sel);
        id r = NBResolve(raw);
        [dbg appendFormat:@"%@ -> raw=%@ resolved=%@\n", sel,
            raw ? NSStringFromClass([raw class]) : @"nil", r ? NSStringFromClass([r class]) : @"nil"];
        if ([r isKindOfClass:[NSArray class]] && [(NSArray *)r count]) return r;
        if ([r isKindOfClass:[NSSet class]] && [(NSSet *)r count]) return [(NSSet *)r allObjects];
    }
    for (NSString *sel in @[@"currentTimerSync", @"currentTimer"]) {
        id raw = NBPerform(mgr, sel);
        id r = NBResolve(raw);
        [dbg appendFormat:@"%@ -> raw=%@ resolved=%@\n", sel,
            raw ? NSStringFromClass([raw class]) : @"nil", r ? NSStringFromClass([r class]) : @"nil"];
        if (r && ![r isKindOfClass:[NSNull class]] && ![r isKindOfClass:[NSArray class]]) return @[r];
    }
    return @[];
}

static id NBFetchAlarm(id mgr, NSMutableString *dbg) {
    for (NSString *sel in @[@"nextAlarmSync", @"nextAlarm"]) {
        id raw = NBPerform(mgr, sel);
        id r = NBResolve(raw);
        [dbg appendFormat:@"%@ -> raw=%@ resolved=%@\n", sel,
            raw ? NSStringFromClass([raw class]) : @"nil", r ? NSStringFromClass([r class]) : @"nil"];
        if ([r isKindOfClass:[NSArray class]]) r = [(NSArray *)r firstObject];
        if (r && ![r isKindOfClass:[NSNull class]]) return r;
    }
    return nil;
}

#ifdef NB_DEBUG
static void NBAppendMethods(NSMutableString *out, Class cls, BOOL meta) {
    if (!cls) return;
    Class c = meta ? object_getClass(cls) : cls;
    unsigned int n = 0;
    Method *list = class_copyMethodList(c, &n);
    [out appendFormat:@"%@%@ methods (%u)\n", meta ? @"+" : @"-", NSStringFromClass(cls), n];
    for (unsigned int i = 0; i < n; i++) [out appendFormat:@"  %@\n", NSStringFromSelector(method_getName(list[i]))];
    free(list);
}

static void NBAppendProps(NSMutableString *out, Class cls) {
    if (!cls) return;
    unsigned int n = 0;
    objc_property_t *list = class_copyPropertyList(cls, &n);
    [out appendFormat:@"%@ properties (%u)\n", NSStringFromClass(cls), n];
    for (unsigned int i = 0; i < n; i++) [out appendFormat:@"  %s\n", property_getName(list[i])];
    free(list);
}

static void NBWriteClockDebug(NSString *body) {
    NSMutableString *out = [NSMutableString string];
    [out appendString:body];
    [out appendString:@"\n--- classes ---\n"];
    NBAppendMethods(out, NSClassFromString(@"MTTimerManager"), NO);
    NBAppendMethods(out, NSClassFromString(@"MTTimerManager"), YES);
    NBAppendMethods(out, NSClassFromString(@"MTAlarmManager"), NO);
    NBAppendMethods(out, NSClassFromString(@"MTAlarmManager"), YES);
    NBAppendProps(out, NSClassFromString(@"MTTimer"));
    NBAppendProps(out, NSClassFromString(@"MTAlarm"));
    [out writeToFile:@"/var/mobile/Documents/NowBarX-log.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
#endif

#pragma mark - Data source

@implementation NBDataSource {
    MRGetInfoFn _getInfo;
    MRGetBoolFn _getPlaying;
    MRSendCmdFn _sendCmd;
    MRRegisterFn _register;
    MRGetClientFn _getClient;
    MRClientBIDFn _clientBID;

    NBItem *_media;
    NSArray<NBItem *> *_timers;
    NBItem *_alarm;
    NSArray<NBItem *> *_items;

    id _timerMgr;
    id _alarmMgr;
    NSTimer *_poll;
    UIImage *_art;
    UIColor *_artTint;
    NSString *_artKey;
    BOOL _started;
    NSDate *_demoAnchor;
}

+ (instancetype)shared {
    static NBDataSource *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[NBDataSource alloc] init]; });
    return s;
}

- (NSArray<NBItem *> *)items { return _items ?: @[]; }

- (BOOL)hasMedia { return _media != nil; }

#pragma mark Setup

- (void)start {
    if (_started) return;
    _started = YES;

    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    if (mr) {
        _getInfo = (MRGetInfoFn)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
        _getPlaying = (MRGetBoolFn)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        _sendCmd = (MRSendCmdFn)dlsym(mr, "MRMediaRemoteSendCommand");
        _register = (MRRegisterFn)dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
        _getClient = (MRGetClientFn)dlsym(mr, "MRMediaRemoteGetNowPlayingClient");
        _clientBID = (MRClientBIDFn)dlsym(mr, "MRNowPlayingClientGetBundleIdentifier");
    }
    NBLog(@"MediaRemote loaded=%d info=%p playing=%p client=%p", mr != NULL, _getInfo, _getPlaying, _getClient);

    dlopen("/System/Library/PrivateFrameworks/MobileTimer.framework/MobileTimer", RTLD_LAZY);

    if (_register) _register(dispatch_get_main_queue());

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    NSArray *names = @[
        @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
        @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
        @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
    ];
    for (NSString *n in names) {
        [nc addObserverForName:n object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            [self refreshMedia];
        }];
    }
    [nc addObserverForName:NBSettingsChangedNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        [self refreshMedia];
        [self refreshClock];
    }];

    [self refreshMedia];
}

- (void)ensureManagers {
    if (!_timerMgr) {
        Class tm = NSClassFromString(@"MTTimerManager");
        if (tm) _timerMgr = [[tm alloc] init];
    }
    if (!_alarmMgr) {
        Class am = NSClassFromString(@"MTAlarmManager");
        if (am) _alarmMgr = [[am alloc] init];
    }
}

- (void)setPolling:(BOOL)on {
    [_poll invalidate];
    _poll = nil;
    if (!on) return;
    [self refreshMedia];
    [self refreshClock];
    _poll = [NSTimer scheduledTimerWithTimeInterval:3.0 repeats:YES block:^(NSTimer *t) {
        [self refreshClock];
    }];
}

#pragma mark Media

- (void)refreshMedia {
    NBSettings *st = [NBSettings shared];
    if (!st.enabled || !st.showMedia || !_getInfo || !_getPlaying) {
        _media = nil;
        [self rebuild];
        return;
    }
    dispatch_queue_t q = dispatch_get_main_queue();
    void (^withBundle)(NSString *) = ^(NSString *bid) {
        self->_getInfo(q, ^(CFDictionaryRef cf) {
            NSDictionary *info = cf ? (__bridge NSDictionary *)cf : @{};
            self->_getPlaying(q, ^(Boolean playing) {
                [self buildMediaFromInfo:info bundle:bid playing:playing];
            });
        });
    };
    if (_getClient && _clientBID) {
        _getClient(q, ^(CFTypeRef client) {
            NSString *bid = client ? (__bridge NSString *)self->_clientBID(client) : nil;
            withBundle(bid);
        });
    } else {
        withBundle(nil);
    }
}

- (void)buildMediaFromInfo:(NSDictionary *)info bundle:(NSString *)bid playing:(BOOL)playing {
    NBSettings *st = [NBSettings shared];
    NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
    BOOL titleOK = [title isKindOfClass:[NSString class]] && title.length > 0;
    BOOL bundleOK = !st.spotifyOnly || [bid hasPrefix:@"com.spotify"];
    NBLog(@"media bundle=%@ title=%@ playing=%d", bid, title, playing);
    if (!titleOK || !bundleOK) {
        _media = nil;
        [self rebuild];
        return;
    }

    NBItem *it = [NBItem new];
    it.type = NBItemTypeMedia;
    it.key = @"media";
    it.title = title;
    NSString *artist = info[@"kMRMediaRemoteNowPlayingInfoArtist"];
    it.subtitle = [artist isKindOfClass:[NSString class]] ? artist : @"";

    NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
    if (![art isKindOfClass:[NSData class]]) art = nil;
    NSString *ak = [NSString stringWithFormat:@"%@|%@|%lu", title, it.subtitle, (unsigned long)art.length];
    if (![ak isEqualToString:_artKey]) {
        _artKey = ak;
        _art = art.length ? [UIImage imageWithData:art] : nil;
        _artTint = NBTintFromImage(_art);
    }
    it.artwork = _art;
    it.tint = _artTint;

    it.playing = playing;
    it.duration = [info[@"kMRMediaRemoteNowPlayingInfoDuration"] doubleValue];
    it.elapsed = [info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"] doubleValue];
    it.rate = [info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] doubleValue];
    if (it.rate == 0 && playing) it.rate = 1;
    NSDate *ts = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
    it.refDate = [ts isKindOfClass:[NSDate class]] ? ts : [NSDate date];

    _media = it;
    [self rebuild];
}

- (void)mediaCommand:(int)command {
    if (_sendCmd) _sendCmd(command, NULL);
    [self performSelector:@selector(refreshMedia) withObject:nil afterDelay:0.3];
}

#pragma mark Timer / Alarm

- (void)refreshClock {
    NBSettings *st = [NBSettings shared];
    [self ensureManagers];

    NSMutableString *dbg = nil;
#ifdef NB_DEBUG
    dbg = [NSMutableString stringWithFormat:@"now=%@\ntimerMgr=%@\nalarmMgr=%@\n", [NSDate date], _timerMgr, _alarmMgr];
#endif

    NSMutableArray<NBItem *> *timers = [NSMutableArray array];
    if (st.enabled && st.showTimer && _timerMgr) {
        NSArray *list = NBFetchTimers(_timerMgr, dbg);
        NSDate *now = [NSDate date];
        for (id t in list) {
            NSInteger state = [NBVal(t, @"state") integerValue];
            id fireObj = NBVal(t, @"fireDate");
            id remObj = NBVal(t, @"remainingTime");
            id durObj = NBVal(t, @"duration");
            NSDate *fire = [fireObj isKindOfClass:[NSDate class]] ? fireObj : nil;
            NSTimeInterval rem = [remObj doubleValue];
            NSTimeInterval dur = [durObj doubleValue];
            [dbg appendFormat:@"timer %@ state=%ld fire=%@ rem=%@ dur=%@\n", t, (long)state, fireObj, remObj, durObj];

            BOOL running = fire && [fire timeIntervalSinceDate:now] > 0;
            BOOL paused = NO;
            if (!running) {
                // not running by date: paused if the time left is less than the full duration
                paused = (rem > 0.5 && dur > 0 && rem < dur - 0.5) || (state == 3 && rem > 0.5);
            }
            if (!running && !paused && state == 2 && rem > 0.5) {
                running = YES;
                fire = [now dateByAddingTimeInterval:rem];
            }
            if (!running && !paused) continue;

            NBItem *it = [NBItem new];
            it.type = NBItemTypeTimer;
            it.underlying = t;
            it.key = [NSString stringWithFormat:@"timer-%@", NBVal(t, @"timerID") ?: @"x"];
            NSString *name = NBVal(t, @"title");
            it.title = ([name isKindOfClass:[NSString class]] && name.length) ? name : @"Таймер";
            it.paused = paused;
            it.duration = dur > 0 ? dur : rem;
            it.remaining = rem;
            it.refDate = running ? fire : [now dateByAddingTimeInterval:rem];
            [timers addObject:it];
        }
    }
    _timers = timers;

    NBItem *alarmItem = nil;
    if (st.enabled && st.showAlarm && _alarmMgr) {
        id a = NBFetchAlarm(_alarmMgr, dbg);
        if (a) {
            NSDate *fd = NBVal(a, @"nextFireDate");
            if (![fd isKindOfClass:[NSDate class]]) {
                fd = NBNextOccurrence([NBVal(a, @"hour") integerValue], [NBVal(a, @"minute") integerValue]);
            }
            NSTimeInterval until = fd ? [fd timeIntervalSinceNow] : -1;
            [dbg appendFormat:@"alarm %@ fire=%@ until=%.0f window=%.0f min\n", a, fd, until, st.alarmWindow];
            if (until > 0 && until < st.alarmWindow * 60.0) {
                alarmItem = [NBItem new];
                alarmItem.type = NBItemTypeAlarm;
                alarmItem.key = @"alarm";
                NSString *name = NBVal(a, @"title");
                alarmItem.title = ([name isKindOfClass:[NSString class]] && name.length) ? name : @"Будильник";
                NSInteger mins = (NSInteger)ceil(until / 60.0);
                alarmItem.subtitle = mins >= 60
                    ? [NSString stringWithFormat:@"через %ld ч %ld мин", (long)(mins / 60), (long)(mins % 60)]
                    : [NSString stringWithFormat:@"через %ld мин", (long)mins];
                alarmItem.refDate = fd;
            }
        }
    }
    _alarm = alarmItem;

#ifdef NB_DEBUG
    NBWriteClockDebug(dbg);
#endif
    [self rebuild];
}

- (void)toggleTimer:(NBItem *)item {
    id t = item.underlying;
    if (!t || !_timerMgr) return;
    NSString *sel = item.paused ? @"resumeTimer:" : @"pauseTimer:";
    NBPerform1(_timerMgr, sel, t);
    [self performSelector:@selector(refreshClock) withObject:nil afterDelay:0.3];
}

- (void)stopTimer:(NBItem *)item {
    id t = item.underlying;
    if (!t || !_timerMgr) return;
    for (NSString *sel in @[@"removeTimer:", @"cancelTimer:", @"dismissTimer:"]) {
        if ([_timerMgr respondsToSelector:NSSelectorFromString(sel)]) {
            NBPerform1(_timerMgr, sel, t);
            break;
        }
    }
    [self performSelector:@selector(refreshClock) withObject:nil afterDelay:0.3];
}

#pragma mark Merge

// Fake timer, track and alarm for checking the card stack without real events.
- (NSArray<NBItem *> *)demoItems {
    if (!_demoAnchor) _demoAnchor = [NSDate date];
    NSDate *now = [NSDate date];
    NSTimeInterval spent = [now timeIntervalSinceDate:_demoAnchor];

    NBItem *timer = [NBItem new];
    timer.type = NBItemTypeTimer;
    timer.key = @"demo-timer";
    timer.title = @"Таймер";
    timer.duration = 600;
    NSTimeInterval left = 600 - fmod(spent, 600);
    timer.remaining = left;
    timer.refDate = [now dateByAddingTimeInterval:left];

    NBItem *media = [NBItem new];
    media.type = NBItemTypeMedia;
    media.key = @"demo-media";
    media.title = @"Тестовый трек";
    media.subtitle = @"Исполнитель";
    media.playing = YES;
    media.duration = 214;
    media.elapsed = 0;
    media.rate = 1;
    media.refDate = _demoAnchor;
    media.tint = [UIColor colorWithHue:0.60 saturation:0.65 brightness:0.32 alpha:1];

    NBItem *alarm = [NBItem new];
    alarm.type = NBItemTypeAlarm;
    alarm.key = @"demo-alarm";
    alarm.title = @"Будильник";
    alarm.subtitle = @"через 15 мин";
    alarm.refDate = [_demoAnchor dateByAddingTimeInterval:900];

    return @[timer, media, alarm];
}

- (void)rebuild {
    NBSettings *st = [NBSettings shared];
    NSMutableArray<NBItem *> *all = [NSMutableArray array];
    if (st.enabled && st.demoMode) {
        [all addObjectsFromArray:[self demoItems]];
    } else {
        _demoAnchor = nil;
        if (_timers.count) [all addObjectsFromArray:_timers];
        if (_media) [all addObject:_media];
        if (_alarm) [all addObject:_alarm];
    }
    _items = all;
    [[NSNotificationCenter defaultCenter] postNotificationName:NBItemsChangedNotification object:nil];
}

@end
