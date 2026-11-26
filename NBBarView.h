#import <UIKit/UIKit.h>

@interface NBBarView : UIView
- (void)setActive:(BOOL)active;
// Asked regularly: return YES while the passcode screen is up, the bar then fades out.
@property (nonatomic, copy) BOOL (^suppressProbe)(void);
- (CGRect)capsuleFrame;   // resting frame of the collapsed capsule, in the bar's coordinates
- (void)checkSuppressed;
- (void)checkSuppressedAnimated:(BOOL)animated;
@property (nonatomic, copy) void (^tickHook)(void);   // called a few times a second while the lock screen is up
@end
