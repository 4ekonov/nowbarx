#import "NBDataSource.h"
#import "NBSettings.h"
#import <dlfcn.h>
#import <objc/message.h>

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

// MobileTimer managers often return an NAFuture; resolve it synchronously.
static id NBResolve(id v) {
    SEL s = NSSelectorFromString(@"resultWithTimeout:error:");
    if (v && [v respondsToSelector:s]) {
        NSError *err = nil;
        return ((id (*)(id, SEL, double, NSError **))objc_msgSend)(v, s, 1.0, &err);
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
    NSString *_artKey;
    BOOL _started;
}

+ (instancetype)shared {
    static NBDataSource *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[NBDataSource alloc] init]; });
    return s;
}

- (NSArray<NBItem *> *)items { return _items ?: @[]; }

#pragma mark - Setup

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
    Class tm = NSClassFromString(@"MTTimerManager");
    if (tm) _timerMgr = [[tm alloc] init];
    Class am = NSClassFromString(@"MTAlarmManager");
    if (am) _alarmMgr = [[am alloc] init];
    NBLog(@"MTTimerManager=%@ MTAlarmManager=%@", _timerMgr, _alarmMgr);

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
    [self refreshClock];
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

#pragma mark - Media

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
    }
    it.artwork = _art;

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

#pragma mark - Timer / Alarm

- (void)refreshClock {
    NBSettings *st = [NBSettings shared];

    NSMutableArray<NBItem *> *timers = [NSMutableArray array];
    if (st.enabled && st.showTimer && _timerMgr) {
        id list = NBResolve(NBPerform(_timerMgr, @"timers"));
        if ([list isKindOfClass:[NSArray class]]) {
            for (id t in (NSArray *)list) {
                // Assumed MTTimerState: 2 = running, 3 = paused. Verify in the debug log.
                NSInteger state = [NBVal(t, @"state") integerValue];
                NBLog(@"timer state=%ld fire=%@ remaining=%@", (long)state, NBVal(t, @"fireDate"), NBVal(t, @"remainingTime"));
                if (state != 2 && state != 3) continue;

                NBItem *it = [NBItem new];
                it.type = NBItemTypeTimer;
                it.underlying = t;
                it.key = [NSString stringWithFormat:@"timer-%@", NBVal(t, @"timerID") ?: @"x"];
                NSString *name = NBVal(t, @"title");
                it.title = ([name isKindOfClass:[NSString class]] && name.length) ? name : @"Таймер";
                it.paused = (state == 3);
                it.duration = [NBVal(t, @"duration") doubleValue];
                it.remaining = [NBVal(t, @"remainingTime") doubleValue];
                NSDate *fire = NBVal(t, @"fireDate");
                it.refDate = [fire isKindOfClass:[NSDate class]] ? fire : [NSDate dateWithTimeIntervalSinceNow:it.remaining];
                [timers addObject:it];
            }
        }
    }
    _timers = timers;

    NBItem *alarmItem = nil;
    if (st.enabled && st.showAlarm && _alarmMgr) {
        id a = NBResolve(NBPerform(_alarmMgr, @"nextAlarm"));
        if (a) {
            NSDate *fd = NBVal(a, @"nextFireDate");
            if (![fd isKindOfClass:[NSDate class]]) {
                fd = NBNextOccurrence([NBVal(a, @"hour") integerValue], [NBVal(a, @"minute") integerValue]);
            }
            NSTimeInterval until = fd ? [fd timeIntervalSinceNow] : -1;
            NBLog(@"next alarm fire=%@ until=%.0f", fd, until);
            if (until > 0 && until < 12 * 3600) {
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

#pragma mark - Merge

- (void)rebuild {
    NSMutableArray<NBItem *> *all = [NSMutableArray array];
    if (_timers.count) [all addObjectsFromArray:_timers];
    if (_media) [all addObject:_media];
    if (_alarm) [all addObject:_alarm];
    _items = all;
    [[NSNotificationCenter defaultCenter] postNotificationName:NBItemsChangedNotification object:nil];
}

@end
