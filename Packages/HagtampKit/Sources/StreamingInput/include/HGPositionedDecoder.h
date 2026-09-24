#import <Foundation/Foundation.h>
#import <SFBAudioEngine/SFBPCMDecoding.h>

NS_ASSUME_NONNULL_BEGIN

/// A decoder that starts part way through: it moves to its position when
/// the player opens it, on the player's decoding thread. (Opening decoders
/// elsewhere races mpg123's setup, which isn't thread-safe.)
NS_SWIFT_NAME(PositionedDecoder)
@interface HGPositionedDecoder : NSObject <SFBPCMDecoding>
/// `fraction` is 0...1 of the decoder's length.
- (instancetype)initWithDecoder:(id<SFBPCMDecoding>)decoder fraction:(double)fraction;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
