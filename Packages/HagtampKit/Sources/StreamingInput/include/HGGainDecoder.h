#import <Foundation/Foundation.h>
#import <SFBAudioEngine/SFBPCMDecoding.h>

NS_ASSUME_NONNULL_BEGIN

/// A decoder whose output is turned up or down (loudness normalization).
/// The gain goes with the track, so gapless handovers change it on the
/// exact sample; later changes glide over a few milliseconds instead of
/// clicking. Decoders that give integers come out as floating point, so
/// turning up never wraps around.
NS_SWIFT_NAME(GainDecoder)
@interface HGGainDecoder : NSObject <SFBPCMDecoding>
/// `gain` is linear (1 leaves the samples as they are).
- (instancetype)initWithDecoder:(id<SFBPCMDecoding>)decoder gain:(float)gain;
- (instancetype)init NS_UNAVAILABLE;
/// Linear; may be set from any thread, and applies from the next buffer decoded.
@property(atomic) float gain;
/// Whether decoding has begun: the gain it began with is about to be heard.
@property(atomic, readonly) BOOL hasStarted;
@end

NS_ASSUME_NONNULL_END
