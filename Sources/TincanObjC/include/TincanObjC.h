#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and returns the Objective-C exception it raised, if any.
/// Swift cannot catch Objective-C exceptions, and Apple's archive decoders raise them for
/// corrupt input. One damaged message must not crash a command.
NSException *_Nullable TCNCatchException(NS_NOESCAPE void (^block)(void));

/// Decodes a Messages `attributedBody` typedstream into an attributed string.
/// Returns nil for corrupt or unexpected data instead of raising.
NSAttributedString *_Nullable TCNUnarchiveAttributedString(NSData *data);

NS_ASSUME_NONNULL_END
