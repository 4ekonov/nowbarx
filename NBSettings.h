#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

extern NSString *const NBSettingsChangedNotification;

@interface NBSettings : NSObject
@property (nonatomic, readonly) BOOL enabled;
@property (nonatomic, readonly) BOOL showMedia;
@property (nonatomic, readonly) BOOL showTimer;
@property (nonatomic, readonly) BOOL showStopwatch;
@property (nonatomic, readonly) BOOL showAlarm;
@property (nonatomic, readonly) BOOL spotifyOnly;
@property (nonatomic, readonly) BOOL collapsedControls; // prev / next buttons in the collapsed capsule
@property (nonatomic, readonly) BOOL hideStockPlayer;
@property (nonatomic, readonly) BOOL hideUnlockHint;
@property (nonatomic, readonly) BOOL haptics;
@property (nonatomic, readonly) BOOL useBlur;
@property (nonatomic, readonly) BOOL artTint;
@property (nonatomic, readonly) BOOL demoMode;
// ambient cards
@property (nonatomic, readonly) BOOL ambientEnabled;
@property (nonatomic, readonly) BOOL ambFlashlight;
@property (nonatomic, readonly) BOOL ambHotspot;
@property (nonatomic, readonly) BOOL ambLowPower;
@property (nonatomic, readonly) BOOL ambVPN;
@property (nonatomic, readonly) BOOL ambCharging;
@property (nonatomic, readonly) BOOL ambWeather;
@property (nonatomic, readonly) BOOL ambScreenTime;
@property (nonatomic, readonly) CGFloat bottomOffset;
@property (nonatomic, readonly) CGFloat xOffset;
@property (nonatomic, readonly) CGFloat capsuleWidth;
@property (nonatomic, readonly) CGFloat capsuleHeight;
@property (nonatomic, readonly) CGFloat bgOpacity;
@property (nonatomic, readonly) CGFloat alarmWindow; // minutes before the alarm
+ (instancetype)shared;
@end
