#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VCamAudioProxy : NSObject <AVCaptureAudioDataOutputSampleBufferDelegate>
- (instancetype)initWithDelegate:(id<AVCaptureAudioDataOutputSampleBufferDelegate>)delegate;
@end

NS_ASSUME_NONNULL_END
