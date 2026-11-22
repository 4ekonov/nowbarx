#import <UIKit/UIKit.h>

// Actions that can be put on the lock screen buttons beside the capsule.
// Action ids: none, flashlight, camera, wifi, bluetooth, airplane, rotation, lowpower, lock, respring,
//             playpause, next, prev, app_settings, app_calculator, app_clock, app_notes, app_phone,
//             app_messages, app_safari, app_wallet, app_spotify, app_custom
@interface NBActions : NSObject
+ (NSString *)symbolForAction:(NSString *)action active:(BOOL)active;
+ (BOOL)isToggle:(NSString *)action;                 // has an on / off state
+ (BOOL)isActive:(NSString *)action;                 // current state of a toggle
+ (BOOL)requiresHold:(NSString *)action;             // dangerous: needs a long press
+ (void)perform:(NSString *)action customBundle:(NSString *)bundle;
@end
