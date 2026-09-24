#import <Foundation/Foundation.h>
#import <SFBAudioEngine/SFBInputSource.h>

NS_ASSUME_NONNULL_BEGIN

/// An input source for a live network stream (internet radio): bytes arrive
/// with `appendData:` and are dropped once read, so an endless stream keeps
/// only what is in flight. Reads wait for their bytes; it can't seek.
NS_SWIFT_NAME(LiveInputSource)
NS_SWIFT_SENDABLE
@interface HGLiveInputSource : SFBInputSource
- (instancetype)initWithURL:(NSURL *)url;
- (void)appendData:(NSData *)data;
/// The stream ended (nil) or broke (an error); readers get what is left, then the end.
- (void)finishWithError:(nullable NSError *)error;
/// Bytes received and not read yet.
@property(nonatomic, readonly) NSInteger bufferedBytes;
@property(nonatomic, readonly) BOOL finished;
/// Stops readers (the player moved on): pending and later reads end the stream.
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
