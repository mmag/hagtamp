#import "HGAudioStreamDecoder.h"

#import <AVFAudio/AVFAudio.h>
#import <SFBAudioEngine/SFBAudioDecoder.h>

/// Bytes read from the input source at a time.
static const NSInteger HGReadSize = 4096;

@interface HGAudioStreamDecoder ()
- (void)addPackets:(UInt32)count bytes:(UInt32)byteCount data:(const void *)data descriptions:(AudioStreamPacketDescription *)descriptions;
- (void)formatIsReady;
- (BOOL)nextPacket:(AudioBufferList *)ioData description:(AudioStreamPacketDescription *_Nullable *_Nullable)description;
@end

static void propertyListener(void *client, AudioFileStreamID stream, AudioFileStreamPropertyID property, AudioFileStreamPropertyFlags *flags) {
    if (property == kAudioFileStreamProperty_ReadyToProducePackets) {
        [(__bridge HGAudioStreamDecoder *)client formatIsReady];
    }
}

static void packetsProc(void *client, UInt32 byteCount, UInt32 packetCount, const void *data, AudioStreamPacketDescription *descriptions) {
    [(__bridge HGAudioStreamDecoder *)client addPackets:packetCount bytes:byteCount data:data descriptions:descriptions];
}

static OSStatus converterInput(AudioConverterRef converter, UInt32 *packetCount, AudioBufferList *ioData,
                               AudioStreamPacketDescription **description, void *client) {
    HGAudioStreamDecoder *decoder = (__bridge HGAudioStreamDecoder *)client;
    // One packet at a time; none means the stream has ended.
    *packetCount = [decoder nextPacket:ioData description:description] ? 1 : 0;
    return noErr;
}

@implementation HGAudioStreamDecoder {
    SFBInputSource *_inputSource;
    AudioFileTypeID _fileType;
    AudioFileStreamID _stream;
    AudioConverterRef _converter;
    AudioStreamBasicDescription _asbd;
    BOOL _ready;
    BOOL _inputEnded;
    AVAudioFormat *_sourceFormat;
    AVAudioFormat *_processingFormat;
    AVAudioFramePosition _framePosition;
    // Parsed packets waiting for the converter.
    NSMutableData *_packetBytes;
    NSMutableData *_packetDescriptions;
    NSUInteger _next;
    // The packet the converter is working on (it must stay put until the next callback).
    NSData *_current;
    AudioStreamPacketDescription _currentDescription;
}

- (instancetype)initWithInputSource:(SFBInputSource *)inputSource fileType:(AudioFileTypeID)fileType {
    if ((self = [super init])) {
        _inputSource = inputSource;
        _fileType = fileType;
        _packetBytes = [NSMutableData data];
        _packetDescriptions = [NSMutableData data];
    }
    return self;
}

- (void)dealloc {
    [self closeReturningError:nil];
}

- (NSError *)errorWithStatus:(OSStatus)status {
    NSError *underlying = [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
    return [NSError errorWithDomain:SFBAudioDecoderErrorDomain
                               code:SFBAudioDecoderErrorCodeInvalidFormat
                           userInfo:@{NSUnderlyingErrorKey : underlying,
                                      NSLocalizedDescriptionKey : NSLocalizedString(@"The stream's format was not recognized.", @"")}];
}

// MARK: - Parsing

- (void)formatIsReady {
    _ready = YES;
}

- (void)addPackets:(UInt32)count bytes:(UInt32)byteCount data:(const void *)data descriptions:(AudioStreamPacketDescription *)descriptions {
    NSUInteger base = _packetBytes.length;
    [_packetBytes appendBytes:data length:byteCount];
    for (UInt32 i = 0; i < count; i++) {
        AudioStreamPacketDescription description;
        if (descriptions) {
            description = descriptions[i];
        } else {  // constant bit rate
            UInt32 size = _asbd.mBytesPerPacket ?: byteCount / count;
            description = (AudioStreamPacketDescription){.mStartOffset = (SInt64)i * size, .mVariableFramesInPacket = 0, .mDataByteSize = size};
        }
        description.mStartOffset += (SInt64)base;
        [_packetDescriptions appendBytes:&description length:sizeof description];
    }
}

/// Reads and parses more of the stream; NO at its end.
- (BOOL)readMore:(NSError **)error {
    uint8_t buffer[HGReadSize];
    NSInteger count = 0;
    if (![_inputSource readBytes:buffer length:HGReadSize bytesRead:&count error:error] || count == 0) {
        _inputEnded = YES;
        return NO;
    }
    OSStatus status = AudioFileStreamParseBytes(_stream, (UInt32)count, buffer, 0);
    if (status != noErr) {
        if (error) {
            *error = [self errorWithStatus:status];
        }
        _inputEnded = YES;
        return NO;
    }
    return YES;
}

- (BOOL)nextPacket:(AudioBufferList *)ioData description:(AudioStreamPacketDescription **)description {
    NSUInteger count = _packetDescriptions.length / sizeof(AudioStreamPacketDescription);
    while (_next >= count) {
        // Everything handed over: start the queue afresh, then wait for more.
        [_packetBytes setLength:0];
        [_packetDescriptions setLength:0];
        _next = 0;
        if (_inputEnded || ![self readMore:nil]) {
            ioData->mBuffers[0].mDataByteSize = 0;
            return NO;
        }
        count = _packetDescriptions.length / sizeof(AudioStreamPacketDescription);
    }
    AudioStreamPacketDescription packet = ((const AudioStreamPacketDescription *)_packetDescriptions.bytes)[_next++];
    _current = [_packetBytes subdataWithRange:NSMakeRange((NSUInteger)packet.mStartOffset, packet.mDataByteSize)];
    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0].mData = (void *)_current.bytes;
    ioData->mBuffers[0].mDataByteSize = packet.mDataByteSize;
    ioData->mBuffers[0].mNumberChannels = _asbd.mChannelsPerFrame;
    if (description) {
        _currentDescription = packet;
        _currentDescription.mStartOffset = 0;
        *description = &_currentDescription;
    }
    return YES;
}

// MARK: - SFBAudioDecoding

- (SFBInputSource *)inputSource {
    return _inputSource;
}

- (AVAudioFormat *)sourceFormat {
    return _sourceFormat;
}

- (AVAudioFormat *)processingFormat {
    return _processingFormat;
}

- (BOOL)decodingIsLossless {
    return NO;
}

- (NSDictionary<SFBAudioDecodingPropertiesKey, SFBAudioDecodingPropertiesValue> *)properties {
    return @{};
}

- (BOOL)isOpen {
    return _converter != NULL;
}

- (BOOL)openReturningError:(NSError **)error {
    if (!_inputSource.isOpen && ![_inputSource openReturningError:error]) {
        return NO;
    }
    OSStatus status = AudioFileStreamOpen((__bridge void *)self, propertyListener, packetsProc, _fileType, &_stream);
    if (status != noErr) {
        if (error) {
            *error = [self errorWithStatus:status];
        }
        return NO;
    }
    while (!_ready) {
        NSError *readError = nil;
        if (![self readMore:&readError]) {
            if (error) {
                *error = readError ?: [self errorWithStatus:kAudioFileStreamError_DataUnavailable];
            }
            [self closeReturningError:nil];
            return NO;
        }
    }

    UInt32 size = sizeof _asbd;
    AudioFileStreamGetProperty(_stream, kAudioFileStreamProperty_DataFormat, &size, &_asbd);
    [self chooseBestFormat];

    AVAudioChannelLayout *layout = nil;
    if (_asbd.mChannelsPerFrame > 2) {
        layout = [AVAudioChannelLayout layoutWithLayoutTag:kAudioChannelLayoutTag_DiscreteInOrder | _asbd.mChannelsPerFrame];
    }
    _processingFormat = layout
        ? [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:_asbd.mSampleRate interleaved:NO channelLayout:layout]
        : [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:_asbd.mSampleRate channels:_asbd.mChannelsPerFrame interleaved:NO];
    _sourceFormat = [[AVAudioFormat alloc] initWithStreamDescription:&_asbd];
    status = _processingFormat ? AudioConverterNew(&_asbd, _processingFormat.streamDescription, &_converter) : kAudioConverterErr_FormatNotSupported;
    if (status != noErr) {
        if (error) {
            *error = [self errorWithStatus:status];
        }
        [self closeReturningError:nil];
        return NO;
    }
    UInt32 cookieSize = 0;
    if (AudioFileStreamGetPropertyInfo(_stream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, NULL) == noErr && cookieSize > 0) {
        NSMutableData *cookie = [NSMutableData dataWithLength:cookieSize];
        if (AudioFileStreamGetProperty(_stream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, cookie.mutableBytes) == noErr) {
            AudioConverterSetProperty(_converter, kAudioConverterDecompressionMagicCookie, cookieSize, cookie.bytes);
        }
    }
    return YES;
}

/// The stream's format list comes best first (HE-AAC v2, HE-AAC, AAC).
- (void)chooseBestFormat {
    UInt32 listSize = 0;
    if (AudioFileStreamGetPropertyInfo(_stream, kAudioFileStreamProperty_FormatList, &listSize, NULL) != noErr || listSize == 0) {
        return;
    }
    NSMutableData *list = [NSMutableData dataWithLength:listSize];
    if (AudioFileStreamGetProperty(_stream, kAudioFileStreamProperty_FormatList, &listSize, list.mutableBytes) != noErr) {
        return;
    }
    UInt32 idsSize = 0;
    if (AudioFormatGetPropertyInfo(kAudioFormatProperty_DecodeFormatIDs, 0, NULL, &idsSize) != noErr) {
        return;
    }
    NSMutableData *ids = [NSMutableData dataWithLength:idsSize];
    if (AudioFormatGetProperty(kAudioFormatProperty_DecodeFormatIDs, 0, NULL, &idsSize, ids.mutableBytes) != noErr) {
        return;
    }
    const AudioFormatListItem *items = list.bytes;
    const OSType *decodable = ids.bytes;
    for (NSUInteger i = 0; i < listSize / sizeof(AudioFormatListItem); i++) {
        for (NSUInteger j = 0; j < idsSize / sizeof(OSType); j++) {
            if (items[i].mASBD.mFormatID == decodable[j]) {
                _asbd = items[i].mASBD;
                return;
            }
        }
    }
}

- (BOOL)closeReturningError:(NSError **)error {
    if (_converter) {
        AudioConverterDispose(_converter);
        _converter = NULL;
    }
    if (_stream) {
        AudioFileStreamClose(_stream);
        _stream = NULL;
    }
    return YES;
}

- (BOOL)decodeIntoBuffer:(AVAudioBuffer *)buffer error:(NSError **)error {
    AVAudioPCMBuffer *pcm = (AVAudioPCMBuffer *)buffer;
    return [self decodeIntoBuffer:pcm frameLength:pcm.frameCapacity error:error];
}

- (BOOL)supportsSeeking {
    return NO;
}

// MARK: - SFBPCMDecoding

- (AVAudioFramePosition)framePosition {
    return _framePosition;
}

- (AVAudioFramePosition)frameLength {
    return SFBUnknownFrameLength;
}

/// Fills the buffer completely unless the stream ends: the player takes a short buffer for the end.
- (BOOL)decodeIntoBuffer:(AVAudioPCMBuffer *)buffer frameLength:(AVAudioFrameCount)frameLength error:(NSError **)error {
    buffer.frameLength = 0;
    UInt32 frames = MIN(frameLength, buffer.frameCapacity);
    if (frames == 0 || !_converter) {
        return YES;
    }
    AudioBufferList *list = buffer.mutableAudioBufferList;
    for (UInt32 i = 0; i < list->mNumberBuffers; i++) {
        list->mBuffers[i].mDataByteSize = frames * (UInt32)sizeof(float);
    }
    UInt32 produced = frames;
    OSStatus status = AudioConverterFillComplexBuffer(_converter, converterInput, (__bridge void *)self, &produced, list, NULL);
    if (status != noErr) {
        if (error) {
            *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
        }
        return NO;
    }
    buffer.frameLength = produced;
    _framePosition += produced;
    return YES;
}

- (BOOL)seekToFrame:(AVAudioFramePosition)frame error:(NSError **)error {
    if (error) {
        *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ESPIPE userInfo:nil];
    }
    return NO;
}

@end
