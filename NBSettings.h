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
@property (nonatomic, readonly) BOOL hideOnPasscode; // hide the bar while the passcode screen is shown
// ambient cards
@property (nonatomic, readonly) BOOL ambientEnabled;
@property (nonatomic, readonly) BOOL ambFlashlight;
@property (nonatomic, readonly) BOOL ambHotspot;
@property (nonatomic, readonly) BOOL ambLowPower;
@property (nonatomic, readonly) BOOL ambVPN;
@property (nonatomic, readonly) BOOL ambCharging;
@property (nonatomic, readonly) BOOL ambWeather;
@property (nonatomic, readonly) BOOL ambScreenTime;
@property (nonatomic, readonly) BOOL ambLowBattery;
@property (nonatomic, readonly) BOOL ambHeadphones;
@property (nonatomic, readonly) BOOL ambRecording;
@property (nonatomic, readonly) BOOL ambSilent;
@property (nonatomic, readonly) BOOL ambDate;
@property (nonatomic, readonly) BOOL ambStorage;
@property (nonatomic, readonly) CGFloat bottomOffset;
@property (nonatomic, readonly) CGFloat xOffset;
@property (nonatomic, readonly) CGFloat capsuleWidth;
@property (nonatomic, readonly) CGFloat capsuleHeight;
@property (nonatomic, readonly) CGFloat bgOpacity;
@property (nonatomic, readonly) CGFloat cornerRadius; // 0...1, 1 = fully round pill
@property (nonatomic, readonly) CGFloat contentPadX;   // inner padding of the capsule content, pt
@property (nonatomic, readonly) CGFloat contentPadY;
// lock screen buttons beside the capsule
@property (nonatomic, readonly) BOOL btnEnabled;
@property (nonatomic, readonly) CGFloat btnSize;
@property (nonatomic, readonly) CGFloat btnGap;        // distance from the capsule edge
@property (nonatomic, readonly, copy) NSString *btnLeftAction;
@property (nonatomic, readonly, copy) NSString *btnRightAction;
@property (nonatomic, readonly, copy) NSString *btnLeftApp;    // bundle id for the "custom app" action
@property (nonatomic, readonly, copy) NSString *btnRightApp;
@property (nonatomic, readonly) CGFloat alarmWindow; // minutes before the alarm
+ (instancetype)shared;
@end
