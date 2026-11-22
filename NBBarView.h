#import <UIKit/UIKit.h>

@interface NBBarView : UIView
- (void)setActive:(BOOL)active;
// Asked regularly: return YES while the passcode screen is up, the bar then fades out.
@property (nonatomic, copy) BOOL (^suppressProbe)(void);
- (void)checkSuppressed;
@end
