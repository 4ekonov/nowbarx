#import "NBSettings.h"

NSString *const NBSettingsChangedNotification = @"NBSettingsChangedNotification";

static NSString *const kNBSuite = @"com.nowbarx.prefs";
static NSString *const kNBDarwinReload = @"com.nowbarx.prefs/reload";

static void NBPrefsCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NBSettings shared] performSelector:@selector(reload)];
        [[NSNotificationCenter defaultCenter] postNotificationName:NBSettingsChangedNotification object:nil];
    });
}

@implementation NBSettings {
    NSUserDefaults *_defaults;
}

+ (instancetype)shared {
    static NBSettings *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[NBSettings alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _defaults = [[NSUserDefaults alloc] initWithSuiteName:kNBSuite];
        [_defaults registerDefaults:@{
            @"enabled": @YES,
            @"showMedia": @YES,
            @"showTimer": @YES,
            @"showStopwatch": @YES,
            @"collapsedControls": @YES,
            @"ambientEnabled": @YES,
            @"ambFlashlight": @YES,
            @"ambHotspot": @YES,
            @"ambLowPower": @YES,
            @"ambVPN": @YES,
            @"ambCharging": @NO,
            @"ambWeather": @YES,
            @"ambScreenTime": @YES,
            @"showAlarm": @NO,
            @"spotifyOnly": @YES,
            @"hideStockPlayer": @YES,
            @"hideUnlockHint": @YES,
            @"haptics": @YES,
            @"useBlur": @YES,
            @"artTint": @YES,
            @"demoMode": @NO,
            @"bottomOffset": @120.0,
            @"xOffset": @0.0,
            @"capsuleWidth": @235.0,
            @"capsuleHeight": @58.0,
            @"bgOpacity": @0.85,
            @"alarmWindow": @15.0,
        }];
        [self reload];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        (__bridge const void *)self,
                                        NBPrefsCallback,
                                        (__bridge CFStringRef)kNBDarwinReload,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    }
    return self;
}

- (void)reload {
    [_defaults synchronize];
    _enabled = [_defaults boolForKey:@"enabled"];
    _showMedia = [_defaults boolForKey:@"showMedia"];
    _showTimer = [_defaults boolForKey:@"showTimer"];
    _showStopwatch = [_defaults boolForKey:@"showStopwatch"];
    _collapsedControls = [_defaults boolForKey:@"collapsedControls"];
    _ambientEnabled = [_defaults boolForKey:@"ambientEnabled"];
    _ambFlashlight = [_defaults boolForKey:@"ambFlashlight"];
    _ambHotspot = [_defaults boolForKey:@"ambHotspot"];
    _ambLowPower = [_defaults boolForKey:@"ambLowPower"];
    _ambVPN = [_defaults boolForKey:@"ambVPN"];
    _ambCharging = [_defaults boolForKey:@"ambCharging"];
    _ambWeather = [_defaults boolForKey:@"ambWeather"];
    _ambScreenTime = [_defaults boolForKey:@"ambScreenTime"];
    _showAlarm = [_defaults boolForKey:@"showAlarm"];
    _spotifyOnly = [_defaults boolForKey:@"spotifyOnly"];
    _hideStockPlayer = [_defaults boolForKey:@"hideStockPlayer"];
    _hideUnlockHint = [_defaults boolForKey:@"hideUnlockHint"];
    _haptics = [_defaults boolForKey:@"haptics"];
    _useBlur = [_defaults boolForKey:@"useBlur"];
    _artTint = [_defaults boolForKey:@"artTint"];
    _demoMode = [_defaults boolForKey:@"demoMode"];
    _bottomOffset = MAX(0, [_defaults doubleForKey:@"bottomOffset"]);
    _xOffset = [_defaults doubleForKey:@"xOffset"];
    _capsuleWidth = MAX(100, [_defaults doubleForKey:@"capsuleWidth"]);
    _capsuleHeight = MAX(30, [_defaults doubleForKey:@"capsuleHeight"]);
    _bgOpacity = MAX(0.0, MIN(1.0, [_defaults doubleForKey:@"bgOpacity"]));
    _alarmWindow = MAX(1, [_defaults doubleForKey:@"alarmWindow"]);
}

@end
