#import "NBActions.h"
#import "NBAmbient.h"
#import "NBDataSource.h"
#import <objc/message.h>
#import <dlfcn.h>

#pragma mark - Runtime helpers

static BOOL NBResp(id o, NSString *sel) {
    return o && [o respondsToSelector:NSSelectorFromString(sel)];
}

static id NBShared(NSString *cls, NSString *sel) {
    Class c = NSClassFromString(cls);
    if (!NBResp((id)c, sel)) return nil;
    return ((id (*)(id, SEL))objc_msgSend)((id)c, NSSelectorFromString(sel));
}

static BOOL NBGetBool(id o, NSString *sel) {
    if (!NBResp(o, sel)) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(o, NSSelectorFromString(sel));
}

static BOOL NBSetBool(id o, NSString *sel, BOOL v) {
    if (!NBResp(o, sel)) return NO;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(o, NSSelectorFromString(sel), v);
    return YES;
}

static void NBCall(id o, NSString *sel) {
    if (NBResp(o, sel)) ((void (*)(id, SEL))objc_msgSend)(o, NSSelectorFromString(sel));
}

#pragma mark - Individual toggles

static id NBBluetooth(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ dlopen("/System/Library/PrivateFrameworks/BluetoothManager.framework/BluetoothManager", RTLD_LAZY); });
    return NBShared(@"BluetoothManager", @"sharedInstance");
}

static id NBRadios(void) {
    static id radios;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/AppSupport.framework/AppSupport", RTLD_LAZY);
        Class c = NSClassFromString(@"RadiosPreferences");
        if (c) radios = [[c alloc] init];
    });
    return radios;
}

static BOOL NBWiFiOn(void) { return NBGetBool(NBShared(@"SBWiFiManager", @"sharedInstance"), @"wiFiEnabled"); }
static BOOL NBBluetoothOn(void) {
    id bt = NBBluetooth();
    return NBResp(bt, @"powered") ? NBGetBool(bt, @"powered") : NBGetBool(bt, @"enabled");
}
static BOOL NBAirplaneOn(void) { return NBGetBool(NBRadios(), @"airplaneMode"); }
static BOOL NBRotationLocked(void) { return NBGetBool(NBShared(@"SBOrientationLockManager", @"sharedInstance"), @"isUserLocked"); }

static NSString *NBBundleForAction(NSString *a) {
    NSDictionary *m = @{
        @"camera": @"com.apple.camera",
        @"app_settings": @"com.apple.Preferences",
        @"app_calculator": @"com.apple.calculator",
        @"app_clock": @"com.apple.mobiletimer",
        @"app_notes": @"com.apple.mobilenotes",
        @"app_phone": @"com.apple.mobilephone",
        @"app_messages": @"com.apple.MobileSMS",
        @"app_safari": @"com.apple.mobilesafari",
        @"app_wallet": @"com.apple.Passbook",
        @"app_spotify": @"com.spotify.client",
    };
    return m[a];
}

static void NBOpenApp(NSString *bundle) {
    if (!bundle.length) return;
    id ws = NBShared(@"LSApplicationWorkspace", @"defaultWorkspace");
    if (NBResp(ws, @"openApplicationWithBundleID:")) {
        ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, NSSelectorFromString(@"openApplicationWithBundleID:"), bundle);
    }
}

#pragma mark - Public

@implementation NBActions

+ (NSString *)symbolForAction:(NSString *)a active:(BOOL)active {
    NSDictionary *m = @{
        @"flashlight": active ? @"flashlight.on.fill" : @"flashlight.off.fill",
        @"camera": @"camera.fill",
        @"wifi": @"wifi",
        @"bluetooth": @"dot.radiowaves.left.and.right",
        @"airplane": @"airplane",
        @"rotation": @"lock.rotation",
        @"lowpower": @"battery.50",
        @"lock": @"lock.fill",
        @"respring": @"arrow.clockwise",
        @"playpause": @"playpause.fill",
        @"next": @"forward.fill",
        @"prev": @"backward.fill",
        @"app_settings": @"gearshape.fill",
        @"app_calculator": @"plus.slash.minus",
        @"app_clock": @"clock.fill",
        @"app_notes": @"note.text",
        @"app_phone": @"phone.fill",
        @"app_messages": @"message.fill",
        @"app_safari": @"safari.fill",
        @"app_wallet": @"wallet.pass.fill",
        @"app_spotify": @"music.note",
        @"app_custom": @"square.grid.2x2.fill",
    };
    return m[a];
}

+ (BOOL)isToggle:(NSString *)a {
    return [@[@"flashlight", @"wifi", @"bluetooth", @"airplane", @"rotation", @"lowpower"] containsObject:a];
}

+ (BOOL)isActive:(NSString *)a {
    if ([a isEqualToString:@"flashlight"]) return [[NBAmbient shared] isTorchOn];
    if ([a isEqualToString:@"wifi"]) return NBWiFiOn();
    if ([a isEqualToString:@"bluetooth"]) return NBBluetoothOn();
    if ([a isEqualToString:@"airplane"]) return NBAirplaneOn();
    if ([a isEqualToString:@"rotation"]) return NBRotationLocked();
    if ([a isEqualToString:@"lowpower"]) return [NSProcessInfo processInfo].lowPowerModeEnabled;
    return NO;
}

+ (BOOL)requiresHold:(NSString *)a {
    return [a isEqualToString:@"respring"];
}

+ (void)perform:(NSString *)a customBundle:(NSString *)custom {
    if (!a.length || [a isEqualToString:@"none"]) return;

    if ([a isEqualToString:@"flashlight"]) {
        [[NBAmbient shared] setTorchOn:![[NBAmbient shared] isTorchOn]];
    } else if ([a isEqualToString:@"wifi"]) {
        NBSetBool(NBShared(@"SBWiFiManager", @"sharedInstance"), @"setWiFiEnabled:", !NBWiFiOn());
    } else if ([a isEqualToString:@"bluetooth"]) {
        id bt = NBBluetooth();
        BOOL want = !NBBluetoothOn();
        NBSetBool(bt, @"setPowered:", want);
        NBSetBool(bt, @"setEnabled:", want);
    } else if ([a isEqualToString:@"airplane"]) {
        id r = NBRadios();
        NBSetBool(r, @"setAirplaneMode:", !NBAirplaneOn());
        NBCall(r, @"synchronize");
    } else if ([a isEqualToString:@"rotation"]) {
        id m = NBShared(@"SBOrientationLockManager", @"sharedInstance");
        NBCall(m, NBRotationLocked() ? @"unlock" : @"lock");
    } else if ([a isEqualToString:@"lowpower"]) {
        id saver = NBShared(@"_CDBatterySaver", @"batterySaver");
        BOOL want = ![NSProcessInfo processInfo].lowPowerModeEnabled;
        if (NBResp(saver, @"setPowerMode:error:")) {
            NSError *err = nil;
            ((BOOL (*)(id, SEL, long long, NSError **))objc_msgSend)(saver, NSSelectorFromString(@"setPowerMode:error:"), want ? 1 : 0, &err);
        }
    } else if ([a isEqualToString:@"lock"]) {
        UIApplication *app = [UIApplication sharedApplication];
        if (NBResp(app, @"_simulateLockButtonPress")) {
            NBCall(app, @"_simulateLockButtonPress");
        } else {
            id lm = NBShared(@"SBLockScreenManager", @"sharedInstance");
            if (NBResp(lm, @"lockUIFromSource:withOptions:")) {
                ((void (*)(id, SEL, int, id))objc_msgSend)(lm, NSSelectorFromString(@"lockUIFromSource:withOptions:"), 1, nil);
            }
        }
    } else if ([a isEqualToString:@"respring"]) {
        id fb = NBShared(@"FBSystemService", @"sharedInstance");
        if (NBResp(fb, @"exitAndRelaunch:")) NBSetBool(fb, @"exitAndRelaunch:", YES);
    } else if ([a isEqualToString:@"playpause"]) {
        [[NBDataSource shared] mediaCommand:2];
    } else if ([a isEqualToString:@"next"]) {
        [[NBDataSource shared] mediaCommand:4];
    } else if ([a isEqualToString:@"prev"]) {
        [[NBDataSource shared] mediaCommand:5];
    } else if ([a isEqualToString:@"app_custom"]) {
        NBOpenApp(custom);
    } else {
        NBOpenApp(NBBundleForAction(a));
    }
}

@end
