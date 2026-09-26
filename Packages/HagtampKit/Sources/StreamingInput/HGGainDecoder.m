#import "HGGainDecoder.h"

#import <Accelerate/Accelerate.h>

/// How long a change of gain takes to glide in.
static const double kGlideSeconds = 0.05;

@interface HGGainDecoder ()
@property(atomic, readwrite) BOOL hasStarted;
@end

@implementation HGGainDecoder {
    id<SFBPCMDecoding> _decoder;
    /// The output's format; nil until open. Gain applies to deinterleaved float only.
    AVAudioFormat *_format;
    BOOL _canApplyGain;
    /// From the decoder's own format, when it isn't deinterleaved float.
    AVAudioConverter *_converter;
    AVAudioPCMBuffer *_decoded;
    /// The gain being applied, where it is gliding to, and by how much per frame.
    float _applied;
    float _target;
    float _step;
}

- (instancetype)initWithDecoder:(id<SFBPCMDecoding>)decoder gain:(float)gain {
    if ((self = [super init])) {
        _decoder = decoder;
        self.gain = gain;
    }
    return self;
}

- (BOOL)openReturningError:(NSError **)error {
    if (![_decoder openReturningError:error]) {
        return NO;
    }
    AVAudioFormat *format = _decoder.processingFormat;
    _format = format;
    if (format.commonFormat == AVAudioPCMFormatFloat32 && !format.interleaved) {
        _canApplyGain = YES;
        return YES;
    }
    AVAudioFormat *floatFormat =
        format.channelLayout != nil
            ? [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                               sampleRate:format.sampleRate
                                              interleaved:NO
                                            channelLayout:format.channelLayout]
            : [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                               sampleRate:format.sampleRate
                                                 channels:format.channelCount
                                              interleaved:NO];
    AVAudioConverter *converter = floatFormat != nil ? [[AVAudioConverter alloc] initFromFormat:format toFormat:floatFormat] : nil;
    // A format that won't convert plays as it is, without gain.
    if (converter != nil) {
        _format = floatFormat;
        _converter = converter;
        _canApplyGain = YES;
    }
    return YES;
}

- (SFBInputSource *)inputSource { return _decoder.inputSource; }
- (AVAudioFormat *)sourceFormat { return _decoder.sourceFormat; }
- (AVAudioFormat *)processingFormat { return _format ?: _decoder.processingFormat; }
- (BOOL)decodingIsLossless { return _decoder.decodingIsLossless; }
- (NSDictionary<SFBAudioDecodingPropertiesKey, SFBAudioDecodingPropertiesValue> *)properties { return _decoder.properties; }
- (BOOL)closeReturningError:(NSError **)error { return [_decoder closeReturningError:error]; }
- (BOOL)isOpen { return _decoder.isOpen; }
- (BOOL)supportsSeeking { return _decoder.supportsSeeking; }
- (AVAudioFramePosition)framePosition { return _decoder.framePosition; }
- (AVAudioFramePosition)frameLength { return _decoder.frameLength; }

- (BOOL)seekToFrame:(AVAudioFramePosition)frame error:(NSError **)error {
    return [_decoder seekToFrame:frame error:error];
}

- (BOOL)decodeIntoBuffer:(AVAudioBuffer *)buffer error:(NSError **)error {
    AVAudioPCMBuffer *pcm = (AVAudioPCMBuffer *)buffer;
    return [self decodeIntoBuffer:pcm frameLength:pcm.frameCapacity error:error];
}

- (BOOL)decodeIntoBuffer:(AVAudioPCMBuffer *)buffer frameLength:(AVAudioFrameCount)frameLength error:(NSError **)error {
    if (_converter == nil) {
        if (![_decoder decodeIntoBuffer:buffer frameLength:frameLength error:error]) {
            return NO;
        }
    } else {
        if (_decoded == nil || _decoded.frameCapacity < frameLength) {
            _decoded = [[AVAudioPCMBuffer alloc] initWithPCMFormat:_converter.inputFormat frameCapacity:frameLength];
            if (_decoded == nil) {
                if (error != NULL) {
                    *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOMEM userInfo:nil];
                }
                return NO;
            }
        }
        if (![_decoder decodeIntoBuffer:_decoded frameLength:frameLength error:error]) {
            return NO;
        }
        if (_decoded.frameLength == 0) {
            buffer.frameLength = 0;
        } else if (![_converter convertToBuffer:buffer fromBuffer:_decoded error:error]) {
            return NO;
        }
    }
    [self applyGainTo:buffer];
    return YES;
}

- (void)applyGainTo:(AVAudioPCMBuffer *)buffer {
    float gain = self.gain;
    if (!self.hasStarted) {
        // The track starts at its gain rather than gliding in from 1.
        _applied = gain;
        _target = gain;
        self.hasStarted = YES;
    } else if (gain != _target) {
        _target = gain;
        _step = (_target - _applied) / (float)MAX(1.0, kGlideSeconds * _format.sampleRate);
    }
    AVAudioFrameCount frames = buffer.frameLength;
    float *const *channels = buffer.floatChannelData;
    if (!_canApplyGain || channels == NULL || frames == 0) {
        return;
    }
    AVAudioChannelCount channelCount = buffer.format.channelCount;
    AVAudioFrameCount start = 0;
    if (_applied != _target) {
        AVAudioFrameCount remaining = (AVAudioFrameCount)ceilf(fabsf((_target - _applied) / _step));
        AVAudioFrameCount glide = MIN(frames, MAX(1u, remaining));
        for (AVAudioChannelCount channel = 0; channel < channelCount; ++channel) {
            float level = _applied;
            vDSP_vrampmul(channels[channel], 1, &level, &_step, channels[channel], 1, glide);
        }
        _applied = glide >= remaining ? _target : _applied + _step * glide;
        start = glide;
    }
    if (_applied != 1 && start < frames) {
        for (AVAudioChannelCount channel = 0; channel < channelCount; ++channel) {
            vDSP_vsmul(channels[channel] + start, 1, &_applied, channels[channel] + start, 1, frames - start);
        }
    }
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ ×%.3f of %@>", self.class, self.gain, _decoder];
}

@end
