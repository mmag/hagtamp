#import "HGLiveInputSource.h"

#import <errno.h>

// SFBInputSource's designated initializer lives in a private header.
@interface SFBInputSource (HGLiveDesignatedInitializer)
- (instancetype)initWithURL:(nullable NSURL *)url;
@end

/// Read data is dropped from the front of the buffer once this much has piled up.
static const NSUInteger HGCompactThreshold = 256 * 1024;
/// Unread data beyond this (minutes of audio: the stream paused, or a server
/// sending faster than real time) loses its oldest part. A live stream moves
/// on anyway, and the decoders find the next frame.
static const NSUInteger HGMaxUnread = 4 * 1024 * 1024;

@implementation HGLiveInputSource {
    NSCondition *_condition;
    NSMutableData *_buffer;
    NSUInteger _head;  // first unread byte in _buffer
    NSInteger _offset;  // bytes read since the start
    BOOL _finished;
    BOOL _cancelled;
    BOOL _open;
    NSError *_error;
}

- (instancetype)initWithURL:(NSURL *)url {
    if ((self = [super initWithURL:url])) {
        _condition = [[NSCondition alloc] init];
        _buffer = [NSMutableData data];
    }
    return self;
}

- (void)appendData:(NSData *)data {
    [_condition lock];
    [_buffer appendData:data];
    NSUInteger unread = _buffer.length - _head;
    if (unread > HGMaxUnread) {
        NSUInteger drop = unread - HGMaxUnread;
        _head += drop;
        _offset += (NSInteger)drop;
    }
    if (_head >= HGCompactThreshold) {
        [_buffer replaceBytesInRange:NSMakeRange(0, _head) withBytes:NULL length:0];
        _head = 0;
    }
    [_condition broadcast];
    [_condition unlock];
}

- (void)finishWithError:(NSError *)error {
    [_condition lock];
    _finished = YES;
    _error = error;
    [_condition broadcast];
    [_condition unlock];
}

- (void)cancel {
    [_condition lock];
    _cancelled = YES;
    [_condition broadcast];
    [_condition unlock];
}

- (NSInteger)bufferedBytes {
    [_condition lock];
    NSInteger value = (NSInteger)(_buffer.length - _head);
    [_condition unlock];
    return value;
}

- (BOOL)finished {
    [_condition lock];
    BOOL value = _finished;
    [_condition unlock];
    return value;
}

- (BOOL)openReturningError:(NSError **)error {
    _open = YES;
    return YES;
}

- (BOOL)closeReturningError:(NSError **)error {
    _open = NO;
    return YES;
}

- (BOOL)isOpen {
    return _open;
}

- (BOOL)readBytes:(void *)buffer length:(NSInteger)length bytesRead:(NSInteger *)bytesRead error:(NSError **)error {
    *bytesRead = 0;
    if (length <= 0) {
        return YES;
    }
    // Reads are complete unless the stream ends: mpg123 takes a short read
    // for the end of its input. A stalled stream gets half a minute.
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30];
    [_condition lock];
    while ((NSInteger)(_buffer.length - _head) < length && !_finished && !_cancelled) {
        if (![_condition waitUntilDate:deadline]) {
            break;
        }
    }
    NSInteger available = (NSInteger)(_buffer.length - _head);
    BOOL stalled = available < length && !_finished && !_cancelled;
    NSError *failure = _finished ? _error : nil;
    NSInteger count = _cancelled ? 0 : MIN(length, available);
    if (count > 0) {
        memcpy(buffer, (const uint8_t *)_buffer.bytes + _head, (size_t)count);
        _head += (NSUInteger)count;
        _offset += count;
        if (_head >= HGCompactThreshold) {
            [_buffer replaceBytesInRange:NSMakeRange(0, _head) withBytes:NULL length:0];
            _head = 0;
        }
    }
    [_condition unlock];

    if (count == 0 && !_cancelled && (stalled || failure)) {
        if (error) {
            *error = failure ?: [NSError errorWithDomain:NSPOSIXErrorDomain code:ETIMEDOUT userInfo:nil];
        }
        return NO;
    }
    *bytesRead = count;
    return YES;
}

- (BOOL)atEOF {
    [_condition lock];
    BOOL value = _cancelled || (_finished && _head >= _buffer.length);
    [_condition unlock];
    return value;
}

- (BOOL)getOffset:(NSInteger *)offset error:(NSError **)error {
    [_condition lock];
    *offset = _offset;
    [_condition unlock];
    return YES;
}

- (BOOL)getLength:(NSInteger *)length error:(NSError **)error {
    // Endless, as far as anyone knows.
    if (error) {
        *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ESPIPE userInfo:nil];
    }
    return NO;
}

- (BOOL)supportsSeeking {
    return NO;
}

- (BOOL)seekToOffset:(NSInteger)offset error:(NSError **)error {
    if (error) {
        *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ESPIPE userInfo:nil];
    }
    return NO;
}

@end
