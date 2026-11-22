#import "NBAmbient.h"
#import "NBSettings.h"
#import <AVFoundation/AVFoundation.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <sys/socket.h>
#import <objc/message.h>
#import <notify.h>

static NSString *const kDayKey = @"NowBarXScreenDay";
static NSString *const kSecKey = @"NowBarXScreenSeconds";

#pragma mark - Helpers

static BOOL NBHasIPv4Interface(BOOL (^match)(const char *name)) {
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) return NO;
    BOOL found = NO;
    for (struct ifaddrs *a = list; a; a = a->ifa_next) {
        if (!a->ifa_addr || a->ifa_addr->sa_family != AF_INET) continue;
        if (!(a->ifa_flags & IFF_UP)) continue;
        if (match(a->ifa_name)) { found = YES; break; }
    }
    freeifaddrs(list);
    return found;
}

static NSString *NBInterfaceList(void) {
    NSMutableArray *names = [NSMutableArray array];
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) == 0) {
        for (struct ifaddrs *a = list; a; a = a->ifa_next) {
            if (a->ifa_addr && a->ifa_addr->sa_family == AF_INET && (a->ifa_flags & IFF_UP)) {
                NSString *n = [NSString stringWithUTF8String:a->ifa_name];
                if (n && ![names containsObject:n]) [names addObject:n];
            }
        }
        freeifaddrs(list);
    }
    return [names componentsJoinedByString:@","];
}

static UIColor *NBRGB(CGFloat r, CGFloat g, CGFloat b) {
    return [UIColor colorWithRed:r green:g blue:b alpha:1];
}

static BOOL NBResponds(id o, NSString *sel) {
    return o && [o respondsToSelector:NSSelectorFromString(sel)];
}

// WMO weather code (open-meteo) -> text and SF Symbol
static void NBWeatherFor(NSInteger code, BOOL day, NSString **text, NSString **symbol) {
    NSString *t = @"Облачно", *s = @"cloud.fill";
    if (code == 0) { t = @"Ясно"; s = day ? @"sun.max.fill" : @"moon.stars.fill"; }
    else if (code == 1) { t = @"Малооблачно"; s = day ? @"cloud.sun.fill" : @"cloud.moon.fill"; }
    else if (code == 2) { t = @"Облачно с прояснениями"; s = day ? @"cloud.sun.fill" : @"cloud.moon.fill"; }
    else if (code == 3) { t = @"Пасмурно"; s = @"cloud.fill"; }
    else if (code == 45 || code == 48) { t = @"Туман"; s = @"cloud.fog.fill"; }
    else if (code >= 51 && code <= 57) { t = @"Морось"; s = @"cloud.drizzle.fill"; }
    else if (code >= 61 && code <= 67) { t = @"Дождь"; s = @"cloud.rain.fill"; }
    else if (code >= 71 && code <= 77) { t = @"Снег"; s = @"snowflake"; }
    else if (code >= 80 && code <= 82) { t = @"Ливень"; s = @"cloud.heavyrain.fill"; }
    else if (code == 85 || code == 86) { t = @"Снегопад"; s = @"cloud.snow.fill"; }
    else if (code >= 95) { t = @"Гроза"; s = @"cloud.bolt.rain.fill"; }
    *text = t;
    *symbol = s;
}

#pragma mark - Provider

@implementation NBAmbient {
    BOOL _visible;
    NSDate *_unlockedAt;

    // flashlight
    id _flash;                 // AVFlashlight instance (private class), created lazily
    int _ringerToken;
    BOOL _ringerReady;

    // weather
    BOOL _wFetching;
    NSDate *_wNextTry;
    NSString *_wTemp, *_wDesc, *_wCity, *_wSymbol;
    BOOL _wHas;
    double _lat, _lon;
    NSString *_geoCity;
    NSDate *_geoDate;
    NSMutableString *_wLog;

    NSDate *_lastDump;
}

+ (instancetype)shared {
    static NBAmbient *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[NBAmbient alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _wLog = [NSMutableString string];
        dispatch_async(dispatch_get_main_queue(), ^{
            [UIDevice currentDevice].batteryMonitoringEnabled = YES;
        });
    }
    return self;
}

#pragma mark Screen time (own counter)

- (NSString *)dayKey {
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"yyyy-MM-dd";
    return [f stringFromDate:[NSDate date]];
}

- (NSTimeInterval)savedSeconds {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![[d stringForKey:kDayKey] isEqualToString:[self dayKey]]) return 0;
    return [d doubleForKey:kSecKey];
}

- (void)saveSeconds:(NSTimeInterval)s {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:[self dayKey] forKey:kDayKey];
    [d setDouble:s forKey:kSecKey];
}

- (void)setLockScreenVisible:(BOOL)visible {
    if (visible == _visible) return;
    _visible = visible;
    if (visible) {
        if (_unlockedAt) {
            NSTimeInterval used = [[NSDate date] timeIntervalSinceDate:_unlockedAt];
            if (used > 0 && used < 6 * 3600) [self saveSeconds:[self savedSeconds] + used];
            _unlockedAt = nil;
        }
    } else {
        _unlockedAt = [NSDate date];
    }
}

- (NSString *)screenTimeText {
    NSInteger m = (NSInteger)([self savedSeconds] / 60.0);
    if (m >= 60) return [NSString stringWithFormat:@"%ld ч %ld мин", (long)(m / 60), (long)(m % 60)];
    return [NSString stringWithFormat:@"%ld мин", (long)m];
}

#pragma mark Weather: IP geolocation + open-meteo

- (void)wlog:(NSString *)s {
    [_wLog appendFormat:@"%@ %@\n", [NSDate date], s];
    if (_wLog.length > 2500) [_wLog deleteCharactersInRange:NSMakeRange(0, _wLog.length - 1200)];
}

- (void)getJSON:(NSString *)url done:(void (^)(NSDictionary *json))done {
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    r.timeoutInterval = 15;
    [r setValue:@"Mozilla/5.0 (iPhone) NowBarX" forHTTPHeaderField:@"User-Agent"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:r completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSDictionary *json = nil;
        if (data.length) {
            id o = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([o isKindOfClass:[NSDictionary class]]) json = o;
        }
        NSInteger code = [resp isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)resp statusCode] : 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self wlog:[NSString stringWithFormat:@"GET %@ -> http %ld json=%d err=%@", url, (long)code, json != nil, err.localizedDescription ?: @"-"]];
            done(json);
        });
    }] resume];
}

- (void)fetchWeatherIfNeeded {
    if (_wFetching) return;
    if (_wNextTry && [_wNextTry timeIntervalSinceNow] > 0) return;
    _wFetching = YES;
    _wNextTry = [NSDate dateWithTimeIntervalSinceNow:60];   // retry in a minute if something fails

    BOOL haveGeo = (_lat != 0 || _lon != 0) && _geoDate && [_geoDate timeIntervalSinceNow] > -6 * 3600;
    if (haveGeo) { [self fetchForecast]; return; }

    // step 1: approximate position from the IP address
    [self getJSON:@"https://ipwho.is/?lang=ru" done:^(NSDictionary *j) {
        if ([j[@"latitude"] isKindOfClass:[NSNumber class]] && [j[@"longitude"] isKindOfClass:[NSNumber class]]) {
            self->_lat = [j[@"latitude"] doubleValue];
            self->_lon = [j[@"longitude"] doubleValue];
            self->_geoCity = [j[@"city"] isKindOfClass:[NSString class]] ? j[@"city"] : nil;
            self->_geoDate = [NSDate date];
            [self fetchForecast];
            return;
        }
        // fallback service
        [self getJSON:@"https://ipapi.co/json/" done:^(NSDictionary *j2) {
            if ([j2[@"latitude"] isKindOfClass:[NSNumber class]] && [j2[@"longitude"] isKindOfClass:[NSNumber class]]) {
                self->_lat = [j2[@"latitude"] doubleValue];
                self->_lon = [j2[@"longitude"] doubleValue];
                self->_geoCity = [j2[@"city"] isKindOfClass:[NSString class]] ? j2[@"city"] : nil;
                self->_geoDate = [NSDate date];
                [self fetchForecast];
            } else {
                self->_wFetching = NO;
            }
        }];
    }];
}

- (void)fetchForecast {
    NSString *url = [NSString stringWithFormat:
        @"https://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f&current=temperature_2m,weather_code,is_day&timezone=auto",
        _lat, _lon];
    [self getJSON:url done:^(NSDictionary *j) {
        self->_wFetching = NO;
        NSDictionary *cur = [j[@"current"] isKindOfClass:[NSDictionary class]] ? j[@"current"] : nil;
        if (![cur[@"temperature_2m"] isKindOfClass:[NSNumber class]]) return;
        NSInteger temp = lround([cur[@"temperature_2m"] doubleValue]);
        NSInteger code = [cur[@"weather_code"] integerValue];
        BOOL day = [cur[@"is_day"] integerValue] != 0;
        NSString *text = nil, *sym = nil;
        NBWeatherFor(code, day, &text, &sym);
        self->_wTemp = [NSString stringWithFormat:@"%ld°", (long)temp];
        self->_wDesc = text;
        self->_wSymbol = sym;
        self->_wCity = self->_geoCity;
        self->_wHas = YES;
        self->_wNextTry = [NSDate dateWithTimeIntervalSinceNow:20 * 60];
        [[NBDataSource shared] ambientChanged];
    }];
}

#pragma mark Flashlight

// The flashlight is driven by SpringBoard itself, not by AVCaptureDevice, so several sources are asked.
- (BOOL)torchOn:(NSMutableString *)dbg {
    BOOL on = NO;

    Class sb = NSClassFromString(@"SBUIFlashlightController");
    id ctl = NBResponds((id)sb, @"sharedInstance") ? ((id (*)(id, SEL))objc_msgSend)((id)sb, NSSelectorFromString(@"sharedInstance")) : nil;
    if (NBResponds(ctl, @"level")) {
        unsigned long long l = ((unsigned long long (*)(id, SEL))objc_msgSend)(ctl, NSSelectorFromString(@"level"));
        [dbg appendFormat:@"SBUIFlashlightController.level=%llu\n", l];
        if (l > 0) on = YES;
    } else {
        [dbg appendFormat:@"SBUIFlashlightController: %@\n", sb ? @"no level()" : @"class missing"];
    }

    Class fl = NSClassFromString(@"AVFlashlight");
    if (fl) {
        @try {
            if (!_flash) _flash = [[fl alloc] init];
            if (NBResponds(_flash, @"flashlightLevel")) {
                float v = ((float (*)(id, SEL))objc_msgSend)(_flash, NSSelectorFromString(@"flashlightLevel"));
                [dbg appendFormat:@"AVFlashlight.flashlightLevel=%.3f\n", v];
                if (v > 0.001f) on = YES;
            }
        } @catch (__unused NSException *e) { [dbg appendString:@"AVFlashlight exception\n"]; }
    } else {
        [dbg appendString:@"AVFlashlight: class missing\n"];
    }

    AVCaptureDevice *d = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if (d.hasTorch) {
        [dbg appendFormat:@"AVCaptureDevice torchMode=%ld active=%d\n", (long)d.torchMode, d.torchActive];
        if (d.torchMode == AVCaptureTorchModeOn || d.torchActive) on = YES;
    }
    return on;
}

- (BOOL)isTorchOn { return [self torchOn:nil]; }

- (void)torchOff { [self setTorchOn:NO]; }

- (void)setTorchOn:(BOOL)on {
    Class sb = NSClassFromString(@"SBUIFlashlightController");
    id ctl = NBResponds((id)sb, @"sharedInstance") ? ((id (*)(id, SEL))objc_msgSend)((id)sb, NSSelectorFromString(@"sharedInstance")) : nil;
    if (on) {
        if (NBResponds(ctl, @"turnFlashlightOnForReason:")) {
            ((void (*)(id, SEL, id))objc_msgSend)(ctl, NSSelectorFromString(@"turnFlashlightOnForReason:"), @"NowBarX");
        } else if (NBResponds(ctl, @"setLevel:")) {
            ((void (*)(id, SEL, unsigned long long))objc_msgSend)(ctl, NSSelectorFromString(@"setLevel:"), 4);
        }
    } else {
        if (NBResponds(ctl, @"turnFlashlightOffForReason:")) {
            ((void (*)(id, SEL, id))objc_msgSend)(ctl, NSSelectorFromString(@"turnFlashlightOffForReason:"), @"NowBarX");
        } else if (NBResponds(ctl, @"setLevel:")) {
            ((void (*)(id, SEL, unsigned long long))objc_msgSend)(ctl, NSSelectorFromString(@"setLevel:"), 0);
        }
    }
    @try {
        if (!_flash && NSClassFromString(@"AVFlashlight")) _flash = [[NSClassFromString(@"AVFlashlight") alloc] init];
        if (NBResponds(_flash, @"setFlashlightLevel:withError:")) {
            NSError *err = nil;
            ((BOOL (*)(id, SEL, float, NSError **))objc_msgSend)(_flash, NSSelectorFromString(@"setFlashlightLevel:withError:"), on ? 1.0f : 0.0f, &err);
        }
    } @catch (__unused NSException *e) {}
    AVCaptureDevice *d = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    NSError *e = nil;
    if (d.hasTorch && (d.torchMode == AVCaptureTorchModeOn) != on && [d lockForConfiguration:&e]) {
        d.torchMode = on ? AVCaptureTorchModeOn : AVCaptureTorchModeOff;
        [d unlockForConfiguration];
    }
    [[NBDataSource shared] performSelector:@selector(ambientChanged) withObject:nil afterDelay:0.3];
}

#pragma mark Other state probes

- (NSString *)headphonesName {
    @try {
        for (AVAudioSessionPortDescription *p in [AVAudioSession sharedInstance].currentRoute.outputs) {
            NSString *t = p.portType;
            if ([t isEqualToString:AVAudioSessionPortBluetoothA2DP] || [t isEqualToString:AVAudioSessionPortBluetoothHFP] ||
                [t isEqualToString:AVAudioSessionPortBluetoothLE] || [t isEqualToString:AVAudioSessionPortHeadphones]) {
                return p.portName.length ? p.portName : @"Подключены";
            }
        }
    } @catch (__unused NSException *e) {}
    return nil;
}

- (int)ringerState {
    if (!_ringerReady) {
        _ringerReady = (notify_register_check("com.apple.springboard.ringerstate", &_ringerToken) == NOTIFY_STATUS_OK);
    }
    if (!_ringerReady) return -1;
    uint64_t st = 0;
    notify_get_state(_ringerToken, &st);
    return (int)st;
}

- (NSString *)freeStorageText {
    NSURL *u = [NSURL fileURLWithPath:@"/var/mobile"];
    NSDictionary *v = [u resourceValuesForKeys:@[NSURLVolumeAvailableCapacityForImportantUsageKey] error:nil];
    NSNumber *n = v[NSURLVolumeAvailableCapacityForImportantUsageKey];
    if (!n) return nil;
    return [NSString stringWithFormat:@"%.1f ГБ", n.doubleValue / 1e9];
}

#pragma mark Items

- (NBItem *)make:(NSString *)key title:(NSString *)title sub:(NSString *)sub symbol:(NSString *)sym accent:(UIColor *)accent {
    NBItem *it = [NBItem new];
    it.type = NBItemTypeStatus;
    it.key = [@"status-" stringByAppendingString:key];
    it.title = title;
    it.subtitle = sub;
    it.symbol = sym;
    it.accent = accent;
    return it;
}

- (void)dumpDebug:(NSString *)body {
#ifdef NB_DEBUG
    if (_lastDump && [[NSDate date] timeIntervalSinceDate:_lastDump] < 3.0) return;
    _lastDump = [NSDate date];
    NSString *out = [NSString stringWithFormat:@"%@\ninterfaces(IPv4,up)=%@\nlowPower=%d battery=%.2f state=%ld\ncaptured=%d\nringerstate=%d\n--- weather log ---\n%@",
        body, NBInterfaceList(), [NSProcessInfo processInfo].lowPowerModeEnabled,
        [UIDevice currentDevice].batteryLevel, (long)[UIDevice currentDevice].batteryState,
        [UIScreen mainScreen].isCaptured, [self ringerState], _wLog];
    [out writeToFile:@"/var/mobile/Documents/NowBarX-ambient.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
#endif
}

- (NBItem *)currentItem {
    NBSettings *st = [NBSettings shared];
    if (!st.enabled || !st.ambientEnabled) return nil;

    NSMutableString *dbg = [NSMutableString stringWithFormat:@"now=%@\n", [NSDate date]];
    UIDevice *dev = [UIDevice currentDevice];
    BOOL charging = dev.batteryState == UIDeviceBatteryStateCharging || dev.batteryState == UIDeviceBatteryStateFull;
    NBItem *result = nil;

    // 1. things that are "on right now", most important first
    if (!result && st.ambRecording && [UIScreen mainScreen].isCaptured) {
        result = [self make:@"recording" title:@"Запись экрана" sub:@"Идёт запись" symbol:@"record.circle.fill" accent:NBRGB(1.0, 0.27, 0.23)];
    }
    if (!result && st.ambFlashlight && [self torchOn:dbg]) {
        result = [self make:@"flashlight" title:@"Фонарик" sub:@"Включён" symbol:@"flashlight.on.fill" accent:NBRGB(1.0, 0.82, 0.2)];
        result.actionSymbol = @"power";
        __weak typeof(self) ws = self;
        result.action = ^{ [ws torchOff]; };
    }
    if (!result && st.ambHotspot && NBHasIPv4Interface(^BOOL(const char *n) { return strncmp(n, "bridge", 6) == 0; })) {
        result = [self make:@"hotspot" title:@"Точка доступа" sub:@"Включена" symbol:@"personalhotspot" accent:NBRGB(0.25, 0.85, 0.45)];
    }
    if (!result && st.ambVPN && NBHasIPv4Interface(^BOOL(const char *n) {
            return strncmp(n, "utun", 4) == 0 || strncmp(n, "ipsec", 5) == 0 || strncmp(n, "ppp", 3) == 0;
        })) {
        result = [self make:@"vpn" title:@"VPN" sub:@"Подключён" symbol:@"lock.shield.fill" accent:NBRGB(0.3, 0.6, 1.0)];
    }
    if (!result && st.ambLowPower && [NSProcessInfo processInfo].lowPowerModeEnabled) {
        result = [self make:@"lowpower" title:@"Энергосбережение" sub:@"Включено" symbol:@"battery.25" accent:NBRGB(1.0, 0.8, 0.0)];
    }
    if (!result && st.ambLowBattery && !charging && dev.batteryLevel >= 0 && dev.batteryLevel <= 0.2f) {
        NSString *sub = [NSString stringWithFormat:@"%d%%", (int)lround(dev.batteryLevel * 100)];
        result = [self make:@"lowbattery" title:@"Низкий заряд" sub:sub symbol:@"battery.0" accent:NBRGB(1.0, 0.27, 0.23)];
    }
    if (!result && st.ambHeadphones) {
        NSString *name = [self headphonesName];
        if (name) result = [self make:@"headphones" title:@"Наушники" sub:name symbol:@"headphones" accent:NBRGB(0.3, 0.6, 1.0)];
    }
    if (!result && st.ambSilent && [self ringerState] == 0) {
        result = [self make:@"silent" title:@"Без звука" sub:@"Беззвучный режим" symbol:@"bell.slash.fill" accent:NBRGB(1.0, 0.62, 0.04)];
    }

    // 2. passive information: rotates every 10 seconds
    if (!result) {
        NSMutableArray<NBItem *> *passive = [NSMutableArray array];
        if (st.ambCharging && charging && dev.batteryLevel >= 0) {
            NSString *sub = [NSString stringWithFormat:@"%d%%", (int)lround(dev.batteryLevel * 100)];
            [passive addObject:[self make:@"charging" title:@"Зарядка" sub:sub symbol:@"bolt.fill" accent:NBRGB(0.25, 0.85, 0.45)]];
        }
        if (st.ambWeather) {
            [self fetchWeatherIfNeeded];
            if (_wHas) {
                NSString *sub = [NSString stringWithFormat:@"%@  %@", _wTemp, _wDesc ?: @""];
                [passive addObject:[self make:@"weather" title:_wCity.length ? _wCity : @"Погода" sub:sub symbol:_wSymbol ?: @"cloud.fill" accent:NBRGB(0.45, 0.78, 1.0)]];
            }
        }
        if (st.ambDate) {
            NSDateFormatter *f1 = [NSDateFormatter new], *f2 = [NSDateFormatter new];
            f1.locale = f2.locale = [NSLocale localeWithLocaleIdentifier:@"ru_RU"];
            f1.dateFormat = @"EEEE";
            f2.dateFormat = @"d MMMM";
            NSString *wd = [f1 stringFromDate:[NSDate date]];
            if (wd.length) wd = [[[wd substringToIndex:1] uppercaseString] stringByAppendingString:[wd substringFromIndex:1]];
            [passive addObject:[self make:@"date" title:wd sub:[f2 stringFromDate:[NSDate date]] symbol:@"calendar" accent:NBRGB(1.0, 0.35, 0.35)]];
        }
        if (st.ambStorage) {
            NSString *free = [self freeStorageText];
            if (free) [passive addObject:[self make:@"storage" title:@"Свободно в памяти" sub:free symbol:@"internaldrive.fill" accent:NBRGB(0.6, 0.65, 0.75)]];
        }
        if (st.ambScreenTime) {
            [passive addObject:[self make:@"screentime" title:@"Экранное время" sub:[self screenTimeText] symbol:@"hourglass" accent:NBRGB(0.72, 0.52, 1.0)]];
        }
        if (passive.count) {
            NSInteger slot = (NSInteger)([NSDate timeIntervalSinceReferenceDate] / 10.0);
            result = passive[(NSUInteger)(slot % (NSInteger)passive.count)];
        }
    }
    [dbg appendFormat:@"result=%@\n", result.key ?: @"nil"];
    [self dumpDebug:dbg];
    return result;
}

@end
