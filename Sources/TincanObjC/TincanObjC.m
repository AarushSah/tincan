#import "TincanObjC.h"

NSException *_Nullable TCNCatchException(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception;
    }
}

NSAttributedString *_Nullable TCNUnarchiveAttributedString(NSData *data) {
    if (data.length == 0) {
        return nil;
    }
    @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        // Messages writes attributedBody with NSArchiver's typedstream format, which only
        // NSUnarchiver reads. NSKeyedUnarchiver cannot decode it.
        id object = [NSUnarchiver unarchiveObjectWithData:data];
#pragma clang diagnostic pop
        if ([object isKindOfClass:[NSAttributedString class]]) {
            return object;
        }
        if ([object isKindOfClass:[NSString class]]) {
            return [[NSAttributedString alloc] initWithString:object];
        }
        return nil;
    } @catch (NSException *exception) {
        return nil;
    }
}
