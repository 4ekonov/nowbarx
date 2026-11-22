#import "NBAmbient.h"
#import "NBSettings.h"
#import <AVFoundation/AVFoundation.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <sys/socket.h>

static NSString *const kDayKey = @"NowBarXScreenDay";
static NSString *const kSecKey = @"NowBarXScreenSeconds";

// YES when an interface whose name matches has an IPv4 address and is up.
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

static UIColor *NBRGB(CGFloat r, CGFloat g, CGFloat b) {
    return [UIColor colorWithRed:r green:g blue:b alpha:1];
}

static NSString *NBWeatherSymbol(NSInteger code) {
    switch (code) {
        case 113: return @"sun.max.fill";
        case 116: return @"cloud.sun.fill";
        case 119: case 122: return @"cloud.fill";
        case 143: case 248: case 260: return @"cloud.fog.fill";
        case 200: case 386: case 389: case 392: case 395: return @"cloud.bolt.rain.fill";
        case 179: case 227: case 230: case 323: case 326: case 329: case 332: case 335: case 338:
        case 368: case 371: case 350: case 374: case 377: return @"snowflake";
        default: break;
    }
    if (code >= 176 && code <= 359) return @"cloud.rain.fill";
    return @"cloud.fill";
}

@implementation NBAmbient {
    BOOL _visible;
    NSDate *_unlockedAt;       // moment the lock screen went away (phone in use since then)

    // weather cache
    BOOL _wFetching;
    NSDate *_wNextTry;
    NSString *_wTemp, *_wDesc, *_wCity;
    NSInteger _wCode;
    BOOL _wHas;
}

+ (instancetype)shared {
    static NBAmbient *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[NBAmbient alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [UIDevice currentDevice].batteryMonitoringEnabled = YES;
        });
    }
    return self;
}

#pragma mark Screen time (own counter: time the phone spends unlocked, since the tweak was installed)

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

#pragma mark Weather (wttr.in, location by IP)

- (void)fetchWeatherIfNeeded {
    if (_wFetching) return;
    if (_wNextTry && [_wNextTry timeIntervalSinceNow] > 0) return;
    _wFetching = YES;
    _wNextTry = [NSDate dateWithTimeIntervalSinceNow:120];   // retry soon if this fails

    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://wttr.in/?format=j1&lang=ru"]];
    r.timeoutInterval = 15;
    [r setValue:@"curl/8.4.0" forHTTPHeaderField:@"User-Agent"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:r completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSString *temp = nil, *desc = nil, *city = nil;
        NSInteger code = 0;
        BOOL ok = NO;
        @try {
            id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSDictionary *cur = [json[@"current_condition"] firstObject];
            if ([cur isKindOfClass:[NSDictionary class]]) {
                temp = [cur[@"temp_C"] description];
                code = [cur[@"weatherCode"] integerValue];
                desc = [[cur[@"lang_ru"] firstObject][@"value"] description] ?: [[cur[@"weatherDesc"] firstObject][@"value"] description];
                city = [[[json[@"nearest_area"] firstObject][@"areaName"] firstObject][@"value"] description];
                ok = temp.length > 0;
            }
        } @catch (__unused NSException *e) { ok = NO; }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_wFetching = NO;
            if (!ok) return;
            self->_wTemp = temp;
            self->_wDesc = desc;
            self->_wCity = city;
            self->_wCode = code;
            self->_wHas = YES;
            self->_wNextTry = [NSDate dateWithTimeIntervalSinceNow:20 * 60];
            [[NBDataSource shared] ambientChanged];
        });
    }] resume];
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

- (BOOL)torchOn {
    AVCaptureDevice *d = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    return d && d.hasTorch && (d.torchMode == AVCaptureTorchModeOn || d.torchActive);
}

- (void)torchOff {
    AVCaptureDevice *d = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    NSError *e = nil;
    if (d.hasTorch && [d lockForConfiguration:&e]) {
        d.torchMode = AVCaptureTorchModeOff;
        [d unlockForConfiguration];
    }
    [[NBDataSource shared] performSelector:@selector(ambientChanged) withObject:nil afterDelay:0.3];
}

- (NBItem *)currentItem {
    NBSettings *st = [NBSettings shared];
    if (!st.enabled || !st.ambientEnabled) return nil;

    // 1. things that are "on right now", most important first
    if (st.ambFlashlight && [self torchOn]) {
        NBItem *it = [self make:@"flashlight" title:@"Фонарик" sub:@"Включён" symbol:@"flashlight.on.fill" accent:NBRGB(1.0, 0.82, 0.2)];
        it.actionSymbol = @"power";
        __weak typeof(self) ws = self;
        it.action = ^{ [ws torchOff]; };
        return it;
    }
    if (st.ambHotspot && NBHasIPv4Interface(^BOOL(const char *n) { return strncmp(n, "bridge", 6) == 0; })) {
        return [self make:@"hotspot" title:@"Точка доступа" sub:@"Включена" symbol:@"personalhotspot" accent:NBRGB(0.25, 0.85, 0.45)];
    }
    if (st.ambLowPower && [NSProcessInfo processInfo].lowPowerModeEnabled) {
        return [self make:@"lowpower" title:@"Энергосбережение" sub:@"Включено" symbol:@"battery.25" accent:NBRGB(1.0, 0.8, 0.0)];
    }
    if (st.ambVPN && NBHasIPv4Interface(^BOOL(const char *n) {
            return strncmp(n, "utun", 4) == 0 || strncmp(n, "ipsec", 5) == 0 || strncmp(n, "ppp", 3) == 0;
        })) {
        return [self make:@"vpn" title:@"VPN" sub:@"Подключён" symbol:@"lock.shield.fill" accent:NBRGB(0.3, 0.6, 1.0)];
    }

    // 2. passive information: rotates every 10 seconds
    NSMutableArray<NBItem *> *passive = [NSMutableArray array];
    UIDevice *dev = [UIDevice currentDevice];
    if (st.ambCharging && (dev.batteryState == UIDeviceBatteryStateCharging || dev.batteryState == UIDeviceBatteryStateFull) && dev.batteryLevel >= 0) {
        NSString *sub = [NSString stringWithFormat:@"%d%%", (int)lround(dev.batteryLevel * 100)];
        [passive addObject:[self make:@"charging" title:@"Зарядка" sub:sub symbol:@"bolt.fill" accent:NBRGB(0.25, 0.85, 0.45)]];
    }
    if (st.ambWeather) {
        [self fetchWeatherIfNeeded];
        if (_wHas) {
            NSString *sub = [NSString stringWithFormat:@"%@°  %@", _wTemp, _wDesc ?: @""];
            [passive addObject:[self make:@"weather" title:_wCity.length ? _wCity : @"Погода" sub:sub symbol:NBWeatherSymbol(_wCode) accent:NBRGB(0.45, 0.78, 1.0)]];
        }
    }
    if (st.ambScreenTime) {
        [passive addObject:[self make:@"screentime" title:@"Экранное время" sub:[self screenTimeText] symbol:@"hourglass" accent:NBRGB(0.72, 0.52, 1.0)]];
    }
    if (!passive.count) return nil;
    NSInteger slot = (NSInteger)([NSDate timeIntervalSinceReferenceDate] / 10.0);
    return passive[(NSUInteger)(slot % (NSInteger)passive.count)];
}

@end
