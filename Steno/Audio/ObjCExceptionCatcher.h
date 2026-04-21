#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Bridges ObjC @try/@catch to Swift. AVAudioNode.installTap(onBus:) throws
/// NSException (not Swift Error) for format mismatches and duplicate taps.
/// Swift cannot catch NSException — this wrapper converts them to NSError.
@interface ObjCExceptionCatcher : NSObject
+ (BOOL)catching:(void (NS_NOESCAPE ^)(void))tryBlock error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
