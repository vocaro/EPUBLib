#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <os/log.h>
#include <string.h>
#include <stdlib.h>
#include <TargetConditionals.h>
#if !TARGET_OS_SIMULATOR || !defined(__arm64__)
#error This hook is only for an arm64 iOS simulator, never a device or Mac process.
#endif

static BOOL useCursor(id self, SEL selector) { return NO; }
__attribute__((constructor)) static void enableCursorActivation(void) {
    if (strcmp(getprogname(), "vot") != 0) return;
    Method method = class_getInstanceMethod(objc_getClass("VOTElementManager"),
                                           sel_registerName("_shouldSendTapStraightToSystem"));
    // iOS 27.2 24B5110a only. The runner also pins the entire executable's SHA-256.
    // Check both the calling convention and original instructions before changing anything.
    const unsigned char expected[] = {0x28,0x00,0x80,0x52,0x09,0xe0,0x5f,0x39,
                                      0x00,0x01,0x29,0x0a,0xc0,0x03,0x5f,0xd6};
    if (!method || strcmp(method_getTypeEncoding(method), "B16@0:8") != 0 ||
        memcmp((const void *)method_getImplementation(method), expected, sizeof(expected)) != 0) {
        os_log_error(OS_LOG_DEFAULT, "EPUB495: refused unknown activation gate v1");
        return;
    }
    method_setImplementation(method, (IMP)useCursor);
    os_log_error(OS_LOG_DEFAULT, "EPUB495: cursor activation v1 enabled build 24B5110a");
}
