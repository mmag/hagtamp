#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#import <SFBAudioEngine/SFBInputSource.h>
#import <SFBAudioEngine/SFBPCMDecoding.h>

NS_ASSUME_NONNULL_BEGIN

/// Decodes a stream that can't seek or tell its length (AAC internet
/// radio) with Audio Toolbox's stream parser and converter. SFBAudioEngine's
/// Core Audio decoder needs a file it can measure and seek.
///
/// HE-AAC streams play at their full quality: the best decodable format in
/// the stream's format list wins over the plain AAC core.
NS_SWIFT_NAME(AudioStreamDecoder)
@interface HGAudioStreamDecoder : NSObject <SFBPCMDecoding>
- (instancetype)initWithInputSource:(SFBInputSource *)inputSource fileType:(AudioFileTypeID)fileType;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
