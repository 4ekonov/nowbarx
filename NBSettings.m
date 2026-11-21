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
            @"showAlarm": @YES,
            @"spotifyOnly": @YES,
            @"haptics": @YES,
            @"bottomOffset": @120.0,
            @"xOffset": @0.0,
            @"scale": @1.0,
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
    _showAlarm = [_defaults boolForKey:@"showAlarm"];
    _spotifyOnly = [_defaults boolForKey:@"spotifyOnly"];
    _haptics = [_defaults boolForKey:@"haptics"];
    _bottomOffset = [_defaults doubleForKey:@"bottomOffset"];
    _xOffset = [_defaults doubleForKey:@"xOffset"];
    _scale = MAX(0.5, [_defaults doubleForKey:@"scale"]);
}

@end
