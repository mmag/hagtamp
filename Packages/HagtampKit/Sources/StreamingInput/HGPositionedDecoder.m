#import "HGPositionedDecoder.h"

@implementation HGPositionedDecoder {
    id<SFBPCMDecoding> _decoder;
    double _fraction;
}

- (instancetype)initWithDecoder:(id<SFBPCMDecoding>)decoder fraction:(double)fraction {
    if ((self = [super init])) {
        _decoder = decoder;
        _fraction = MIN(1, MAX(0, fraction));
    }
    return self;
}

- (BOOL)openReturningError:(NSError **)error {
    if (![_decoder openReturningError:error]) {
        return NO;
    }
    AVAudioFramePosition length = _decoder.frameLength;
    if (_decoder.supportsSeeking && length > 0) {
        // Starting from the top is better than not starting.
        [_decoder seekToFrame:MIN(length - 1, (AVAudioFramePosition)(_fraction * length)) error:nil];
    }
    return YES;
}

- (SFBInputSource *)inputSource { return _decoder.inputSource; }
- (AVAudioFormat *)sourceFormat { return _decoder.sourceFormat; }
- (AVAudioFormat *)processingFormat { return _decoder.processingFormat; }
- (BOOL)decodingIsLossless { return _decoder.decodingIsLossless; }
- (NSDictionary<SFBAudioDecodingPropertiesKey, SFBAudioDecodingPropertiesValue> *)properties { return _decoder.properties; }
- (BOOL)closeReturningError:(NSError **)error { return [_decoder closeReturningError:error]; }
- (BOOL)isOpen { return _decoder.isOpen; }
- (BOOL)supportsSeeking { return _decoder.supportsSeeking; }
- (AVAudioFramePosition)framePosition { return _decoder.framePosition; }
- (AVAudioFramePosition)frameLength { return _decoder.frameLength; }

- (BOOL)decodeIntoBuffer:(AVAudioBuffer *)buffer error:(NSError **)error {
    return [_decoder decodeIntoBuffer:buffer error:error];
}

- (BOOL)decodeIntoBuffer:(AVAudioPCMBuffer *)buffer frameLength:(AVAudioFrameCount)frameLength error:(NSError **)error {
    return [_decoder decodeIntoBuffer:buffer frameLength:frameLength error:error];
}

- (BOOL)seekToFrame:(AVAudioFramePosition)frame error:(NSError **)error {
    return [_decoder seekToFrame:frame error:error];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ %.3f of %@>", self.class, _fraction, _decoder];
}

@end
