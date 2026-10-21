#import "ObjCTry.h"

NSString * _Nullable DiktovkaTryBlock(void (NS_NOESCAPE ^ _Nonnull block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"%@: %@", e.name, e.reason ?: @"без причины"];
    }
}
