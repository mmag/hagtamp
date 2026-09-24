#import "HGStreamingInputSource.h"

#import <errno.h>
#import <fcntl.h>
#import <unistd.h>

// SFBInputSource's designated initializer lives in a private header.
@interface SFBInputSource (HGDesignatedInitializer)
- (instancetype)initWithURL:(nullable NSURL *)url;
@end

@implementation HGStreamState {
    NSCondition *_condition;
    NSInteger _expectedLength;
    NSInteger _available;
    BOOL _finished;
    NSError *_error;
}

- (instancetype)init {
    if ((self = [super init])) {
        _condition = [[NSCondition alloc] init];
        _expectedLength = -1;
    }
    return self;
}

- (NSInteger)expectedLength {
    [_condition lock];
    NSInteger value = _expectedLength;
    [_condition unlock];
    return value;
}

- (NSInteger)available {
    [_condition lock];
    NSInteger value = _available;
    [_condition unlock];
    return value;
}

- (BOOL)finished {
    [_condition lock];
    BOOL value = _finished;
    [_condition unlock];
    return value;
}

- (NSError *)error {
    [_condition lock];
    NSError *value = _error;
    [_condition unlock];
    return value;
}

- (void)setExpectedLength:(NSInteger)length {
    [_condition lock];
    _expectedLength = length;
    [_condition unlock];
}

- (void)appendedBytes:(NSInteger)count {
    [_condition lock];
    _available += count;
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

- (void)wakeReaders {
    [_condition lock];
    [_condition broadcast];
    [_condition unlock];
}

- (NSInteger)waitForLength:(NSInteger)length timeout:(NSTimeInterval)timeout stop:(BOOL (^)(void))stop {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    [_condition lock];
    while (_available < length && !_finished && !stop()) {
        if (![_condition waitUntilDate:deadline]) {
            break;
        }
    }
    NSInteger value = _available;
    [_condition unlock];
    return value;
}

@end

@implementation HGStreamingInputSource {
    NSURL *_partialFile;
    int _fd;
    NSInteger _offset;
    BOOL _seekable;
    _Atomic(BOOL) _cancelled;
}

- (void)cancel {
    _cancelled = YES;
    [_state wakeReaders];
}

- (instancetype)initWithURL:(NSURL *)url partialFile:(NSURL *)partialFile state:(HGStreamState *)state {
    if ((self = [super initWithURL:url])) {
        _partialFile = partialFile;
        _state = state;
        _fd = -1;
    }
    return self;
}

- (NSError *)errorWithCode:(int)code {
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
}

- (BOOL)openReturningError:(NSError **)error {
    // Decided before opening: once the download completed, the part is there in full.
    _seekable = _state.finished && _state.error == nil;
    _fd = open(_partialFile.fileSystemRepresentation, O_RDONLY);
    if (_fd == -1 && errno == ENOENT) {
        // The download finished and was moved into place before we opened it.
        _fd = open(self.url.fileSystemRepresentation, O_RDONLY);
    }
    if (_fd == -1) {
        if (error) {
            *error = [self errorWithCode:errno];
        }
        return NO;
    }
    _offset = 0;
    return YES;
}

- (BOOL)closeReturningError:(NSError **)error {
    if (_fd != -1) {
        close(_fd);
        _fd = -1;
    }
    return YES;
}

- (BOOL)isOpen {
    return _fd != -1;
}

- (BOOL)readBytes:(void *)buffer length:(NSInteger)length bytesRead:(NSInteger *)bytesRead error:(NSError **)error {
    if (length <= 0) {
        *bytesRead = 0;
        return YES;
    }
    // Reads are complete unless the stream ends, as with a file: mpg123
    // takes a short read for the end of the input. A stalled download gets a
    // generous minute.
    __weak HGStreamingInputSource *weakSelf = self;
    NSInteger available = [_state waitForLength:_offset + length timeout:60 stop:^BOOL {
        HGStreamingInputSource *strongSelf = weakSelf;
        return strongSelf == nil || strongSelf->_cancelled;
    }];
    NSInteger count = _cancelled ? 0 : MIN(length, available - _offset);
    if (count <= 0 && !_cancelled) {
        NSError *downloadError = _state.finished ? _state.error : [self errorWithCode:ETIMEDOUT];
        if (downloadError) {
            if (error) {
                *error = downloadError;
            }
            return NO;
        }
    }
    if (count <= 0) {
        *bytesRead = 0;  // end of stream (or cancelled)
        return YES;
    }
    ssize_t result = pread(_fd, buffer, (size_t)count, (off_t)_offset);
    if (result < 0) {
        if (error) {
            *error = [self errorWithCode:errno];
        }
        return NO;
    }
    _offset += result;
    *bytesRead = result;
    return YES;
}

- (BOOL)atEOF {
    return _cancelled || (_state.finished && _offset >= _state.available);
}

- (BOOL)getOffset:(NSInteger *)offset error:(NSError **)error {
    *offset = _offset;
    return YES;
}

- (BOOL)getLength:(NSInteger *)length error:(NSError **)error {
    NSInteger expected = _state.expectedLength;
    *length = expected >= 0 ? expected : _state.available;
    return YES;
}

- (BOOL)supportsSeeking {
    return _seekable;
}

- (BOOL)seekToOffset:(NSInteger)offset error:(NSError **)error {
    // vorbisfile doesn't ask supportsSeeking; a failing seek tells it instead.
    if (!_seekable) {
        if (error) {
            *error = [self errorWithCode:ESPIPE];
        }
        return NO;
    }
    _offset = offset;
    return YES;
}

@end
