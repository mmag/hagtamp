#import <Foundation/Foundation.h>
#import <SFBAudioEngine/SFBInputSource.h>

NS_ASSUME_NONNULL_BEGIN

/// Progress of a download that is being played while it arrives. The
/// downloader reports bytes and completion; readers wait for the bytes
/// they need. Thread-safe.
NS_SWIFT_NAME(StreamState)
NS_SWIFT_SENDABLE
@interface HGStreamState : NSObject
/// Total length if the server announced it, else -1.
@property(nonatomic, readonly) NSInteger expectedLength;
@property(nonatomic, readonly) NSInteger available;
@property(nonatomic, readonly) BOOL finished;
@property(nonatomic, readonly, nullable) NSError *error;

- (void)setExpectedLength:(NSInteger)length;
- (void)appendedBytes:(NSInteger)count;
- (void)finishWithError:(nullable NSError *)error;
/// Wakes waiting readers so they can check whether they were cancelled.
- (void)wakeReaders;
/// Waits until `length` bytes are there, the download ends, `stop` returns
/// YES or `timeout` passes; returns the bytes available.
- (NSInteger)waitForLength:(NSInteger)length timeout:(NSTimeInterval)timeout stop:(BOOL (^)(void))stop;
@end

/// An input source reading a file that is still being downloaded: reads
/// past the downloaded part wait for the data instead of hitting the end.
///
/// It is not seekable unless the download had finished when it was opened.
/// Decoders probe seekable sources for their length (mpg123 scans every
/// frame, opusfile reads the last page), which would wait for the whole
/// download; unseekable they just decode from the start.
NS_SWIFT_NAME(StreamingInputSource)
@interface HGStreamingInputSource : SFBInputSource
/// `url` identifies the stream (its extension picks the decoder); bytes are
/// read from `partialFile`, or from `url` once the download renamed it there.
- (instancetype)initWithURL:(NSURL *)url partialFile:(NSURL *)partialFile state:(HGStreamState *)state;
@property(nonatomic, readonly) HGStreamState *state;
/// Stops this reader (the track was skipped): pending and later reads end the stream.
/// Other readers of the same download are unaffected.
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
