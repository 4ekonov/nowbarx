#import "NBDataSource.h"
#import "NBSettings.h"
#import "NBAmbient.h"
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

// Flattens whatever a manager returned (array, set, single object, NSNull) into an array.
static NSArray *NBObjects(id r) {
    if (!r || [r isKindOfClass:[NSNull class]] || [r isKindOfClass:[NSError class]]) return @[];
    if ([r isKindOfClass:[NSArray class]]) return r;
    if ([r isKindOfClass:[NSSet class]]) return [(NSSet *)r allObjects];
    if ([r isKindOfClass:[NSOrderedSet class]]) return [(NSOrderedSet *)r array];
    return @[r];
}

// Calls a manager method that returns an NAFuture (or a plain value) WITHOUT blocking the main thread:
// the result is delivered later, on the main queue. Nothing is called when the method does not exist.
static BOOL NBAsync(id obj, NSString *sel, void (^cb)(id result)) {
    id raw = NBPerform(obj, sel);
    if (!raw) return NO;
    SEL add = NSSelectorFromString(@"addSuccessBlock:");
    if ([raw respondsToSelector:add]) {
        void (^blk)(id) = ^(id res) {
            dispatch_async(dispatch_get_main_queue(), ^{ cb(res); });
        };
        ((id (*)(id, SEL, id))objc_msgSend)(raw, add, blk);
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{ cb(raw); });
    }
    return YES;
}

static BOOL NBLooksLikeTimer(id o) {
    return [o respondsToSelector:NSSelectorFromString(@"remainingTime")] ||
           [o respondsToSelector:NSSelectorFromString(@"fireDate")];
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
    static NSDate *last;
    if (last && [[NSDate date] timeIntervalSinceDate:last] < 2.0) return;   // do not hammer the disk
    last = [NSDate date];
    NSMutableString *out = [NSMutableString string];
    [out appendString:body];
    [out appendString:@"\n--- classes ---\n"];
    NBAppendMethods(out, NSClassFromString(@"MTTimerManager"), NO);
    NBAppendMethods(out, NSClassFromString(@"MTTimerManager"), YES);
    NBAppendMethods(out, NSClassFromString(@"MTAlarmManager"), NO);
    NBAppendMethods(out, NSClassFromString(@"MTAlarmManager"), YES);
    NBAppendMethods(out, NSClassFromString(@"MTStopwatchManager"), NO);
    NBAppendProps(out, NSClassFromString(@"MTTimer"));
    NBAppendProps(out, NSClassFromString(@"MTStopwatch"));
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
    NBItem *_stopwatch;
    NSArray<NBItem *> *_items;

    id _timerMgr;
    id _alarmMgr;
    id _stopMgr;
    NSMutableDictionary<NSString *, NSArray *> *_timerRaw;   // selector name -> what it returned last
    id _stopObj;                                             // latest stopwatch snapshot
    double _stopLastCur;
    NSDate *_stopLastAt;
    NSMutableString *_asyncLog;
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
    if (!_stopMgr) {
        Class sm = NSClassFromString(@"MTStopwatchManager");
        if (sm) _stopMgr = [[sm alloc] init];
    }
    if (!_timerRaw) _timerRaw = [NSMutableDictionary dictionary];
    if (!_asyncLog) _asyncLog = [NSMutableString string];
}

- (void)setPolling:(BOOL)on {
    [_poll invalidate];
    _poll = nil;
    [[NBAmbient shared] setLockScreenVisible:on];
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

#pragma mark Timer / Stopwatch / Alarm

// Asks the Clock managers for fresh data. Results arrive asynchronously (the managers talk to a daemon),
// each answer is cached and the items are rebuilt from the cache.
- (void)refreshClock {
    NBSettings *st = [NBSettings shared];
    [self ensureManagers];

    if (st.enabled && st.showTimer && _timerMgr) {
        for (NSString *sel in @[@"timers", @"currentTimer", @"nextTimer", @"activeTimers"]) {
            BOOL sent = NBAsync(_timerMgr, sel, ^(id res) {
                NSArray *objs = NBObjects(res);
                self->_timerRaw[sel] = objs;
                [self->_asyncLog appendFormat:@"async %@ -> %@ (%lu)\n", sel, res ? NSStringFromClass([res class]) : @"nil", (unsigned long)objs.count];
                [self rebuildClock];
            });
            if (!sent) [_asyncLog appendFormat:@"%@ not available\n", sel];
        }
        // synchronous variants, in case the async ones never answer
        for (NSString *sel in @[@"timersSync", @"currentTimerSync"]) {
            id raw = NBPerform(_timerMgr, sel);
            if (raw) _timerRaw[sel] = NBObjects(NBResolve(raw));
        }
    }

    if (st.enabled && st.showStopwatch && _stopMgr) {
        for (NSString *sel in @[@"currentStopwatch", @"stopwatch"]) {
            NBAsync(_stopMgr, sel, ^(id res) {
                self->_stopObj = ([res isKindOfClass:[NSNull class]] || [res isKindOfClass:[NSError class]]) ? nil : res;
                [self->_asyncLog appendFormat:@"async %@ -> %@\n", sel, res ? NSStringFromClass([res class]) : @"nil"];
                [self rebuildClock];
            });
        }
        for (NSString *sel in @[@"currentStopwatchSync", @"stopwatchSync"]) {
            id raw = NBPerform(_stopMgr, sel);
            if (raw) {
                id r = NBResolve(raw);
                if (r && ![r isKindOfClass:[NSNull class]]) _stopObj = r;
            }
        }
    }
    [self rebuildClock];
}

// Builds timer / stopwatch / alarm items from the cached manager answers.
- (void)rebuildClock {
    NBSettings *st = [NBSettings shared];
    [self ensureManagers];
    NSDate *now = [NSDate date];

    NSMutableString *dbg = nil;
#ifdef NB_DEBUG
    dbg = [NSMutableString stringWithFormat:@"now=%@\ntimerMgr=%@\nalarmMgr=%@\nstopMgr=%@\n", now, _timerMgr, _alarmMgr, _stopMgr];
    [dbg appendFormat:@"--- async log ---\n%@--- raw timers ---\n%@\n", _asyncLog, _timerRaw];
#endif
    if (_asyncLog.length > 3000) [_asyncLog deleteCharactersInRange:NSMakeRange(0, _asyncLog.length - 1500)];

    // ---- timers
    NSMutableArray<NBItem *> *timers = [NSMutableArray array];
    if (st.enabled && st.showTimer && _timerMgr) {
        // the "timers" list is authoritative when present; otherwise merge the single-timer answers
        NSMutableArray *candidates = [NSMutableArray array];
        BOOL authoritative = _timerRaw[@"timers"] || _timerRaw[@"timersSync"];
        for (NSString *sel in _timerRaw) {
            BOOL isList = [sel hasPrefix:@"timers"];
            if (authoritative && !isList) continue;
            for (id o in _timerRaw[sel]) if (NBLooksLikeTimer(o)) [candidates addObject:o];
        }
        NSMutableSet *seen = [NSMutableSet set];
        for (id t in candidates) {
            id idObj = NBVal(t, @"timerID");
            id uniq = idObj ?: [NSValue valueWithNonretainedObject:t];
            if ([seen containsObject:uniq]) continue;
            [seen addObject:uniq];

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
                // state 3 = paused; with no fire date a partly used countdown is also a paused timer
                paused = (state == 3 && rem > 0.5) || (!fire && rem > 0.5 && dur > 0 && rem < dur - 0.5 && state != 1);
            }
            if (!running && !paused && state == 2 && rem > 0.5) {
                running = YES;
                fire = [now dateByAddingTimeInterval:rem];
            }
            if (!running && !paused) continue;

            NBItem *it = [NBItem new];
            it.type = NBItemTypeTimer;
            it.underlying = t;
            it.key = [NSString stringWithFormat:@"timer-%@", idObj ?: @"x"];
            NSString *name = NBVal(t, @"title");
            it.title = ([name isKindOfClass:[NSString class]] && name.length) ? name : @"Таймер";
            it.paused = paused;
            it.duration = dur > 0 ? dur : (rem > 0 ? rem : [fire timeIntervalSinceDate:now]);
            it.remaining = paused ? rem : MAX(0, [fire timeIntervalSinceDate:now]);
            it.refDate = running ? fire : [now dateByAddingTimeInterval:rem];
            [timers addObject:it];
        }
    }
    _timers = timers;

    // ---- stopwatch (private API guessed from the class layout; see NowBarX-log.txt if it does not show)
    NBItem *swItem = nil;
    if (st.enabled && st.showStopwatch && _stopObj) {
        id sw = _stopObj;
        id startObj = NBVal(sw, @"startDate");
        NSDate *start = [startObj isKindOfClass:[NSDate class]] ? startObj : nil;
        id curObj = NBVal(sw, @"currentInterval") ?: NBVal(sw, @"elapsedTime") ?: NBVal(sw, @"accumulatedTime");
        BOOL hasCur = [curObj isKindOfClass:[NSNumber class]];
        double cur = hasCur ? [curObj doubleValue] : 0;
        id runObj = NBVal(sw, @"isRunning") ?: NBVal(sw, @"running");
        NSInteger state = [NBVal(sw, @"state") integerValue];

        double el = hasCur ? cur : (start ? [now timeIntervalSinceDate:start] : 0);
        BOOL running;
        if ([runObj isKindOfClass:[NSNumber class]]) running = [runObj boolValue];
        else if (!hasCur && start) running = YES;
        else if (_stopLastAt && cur > _stopLastCur + 0.2) running = YES;   // value grows between polls
        else running = (state == 2);
        _stopLastCur = cur;
        _stopLastAt = now;
        [dbg appendFormat:@"stopwatch %@ state=%ld start=%@ cur=%@ running=%d el=%.2f\n", sw, (long)state, startObj, curObj, running, el];

        if (running || el > 0.05) {
            swItem = [NBItem new];
            swItem.type = NBItemTypeStopwatch;
            swItem.key = @"stopwatch";
            swItem.title = @"Секундомер";
            swItem.playing = running;
            swItem.paused = !running;
            swItem.elapsed = el;
            swItem.refDate = now;
        }
    }
    _stopwatch = swItem;

    // ---- alarm
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

    NBItem *sw = [NBItem new];
    sw.type = NBItemTypeStopwatch;
    sw.key = @"demo-stopwatch";
    sw.title = @"Секундомер";
    sw.playing = YES;
    sw.elapsed = spent;
    sw.refDate = now;

    return @[timer, sw, media, alarm];
}

- (void)ambientChanged { [self rebuild]; }

- (void)rebuild {
    NBSettings *st = [NBSettings shared];
    NSMutableArray<NBItem *> *all = [NSMutableArray array];
    if (st.enabled && st.demoMode) {
        [all addObjectsFromArray:[self demoItems]];
    } else {
        _demoAnchor = nil;
        if (_timers.count) [all addObjectsFromArray:_timers];
        if (_stopwatch) [all addObject:_stopwatch];
        if (_media) [all addObject:_media];
        if (_alarm) [all addObject:_alarm];
        // permanent cards are never part of the stack: only shown when nothing else is
        if (!all.count) {
            NBItem *amb = [[NBAmbient shared] currentItem];
            if (amb) [all addObject:amb];
        }
    }
    _items = all;
    [[NSNotificationCenter defaultCenter] postNotificationName:NBItemsChangedNotification object:nil];
}

@end
