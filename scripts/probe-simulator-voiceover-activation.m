#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>
#include <string.h>
#include <stdlib.h>
#include <TargetConditionals.h>
#if !TARGET_OS_SIMULATOR || !defined(__arm64__)
#error This hook is only for an arm64 iOS simulator, never a device or Mac process.
#endif

static BOOL useCursor(id self, SEL selector) { return NO; }
static id objectValue(id object, const char *name) {
    return ((id (*)(id, SEL))objc_msgSend)(object, sel_registerName(name));
}

static void (*originalScreenChange)(id, SEL, id);
static void layoutBeforeScreenChange(id self, SEL selector, id data) {
    id next = objectValue(self, "nextElementToFocus");
    id current = objectValue(self, "_currentElement");
    if (next && current && [next isEqual:current]) {
        NSString *oldLabel = objectValue(current, "label");
        NSString *newLabel = objectValue(next, "label");
        if (oldLabel && newLabel && ![oldLabel isEqualToString:newLabel]) {
            // A targeted layout notification renamed the item under the cursor. A later
            // screen update consumes its shared nextElementToFocus without building speech
            // when the AX identity is unchanged. Let VoiceOver's pending layout handler
            // finish first with speech requested: the timer can suppress it for a reused
            // identity despite its changed label. Keep the handler's cursor/rotor rules.
            ((void (*)(id, SEL, BOOL))objc_msgSend)(self, sel_registerName("_handleLayoutChange:"), YES);
            os_log_error(OS_LOG_DEFAULT, "EPUB495: processed renamed target before screen update v3");
        }
    }
    originalScreenChange(self, selector, data);
}

static BOOL matches(Method method, const char *type, const unsigned char *bytes, size_t count) {
    return method && strcmp(method_getTypeEncoding(method), type) == 0 &&
        memcmp((const void *)method_getImplementation(method), bytes, count) == 0;
}

__attribute__((constructor)) static void enableCursorActivation(void) {
    if (strcmp(getprogname(), "vot") != 0) return;
    Class manager = objc_getClass("VOTElementManager");
    Method gate = class_getInstanceMethod(manager, sel_registerName("_shouldSendTapStraightToSystem"));
    Method screen = class_getInstanceMethod(manager, sel_registerName("_handleScreenChangeImpl:"));
    Method layout = class_getInstanceMethod(manager, sel_registerName("_handleLayoutChange:"));
    // iOS 27.2 24B5110a only. The runner pins the entire executable's SHA-256;
    // validate every replaced/called handler before installing either override.
    const unsigned char gateBytes[] = {0x28,0x00,0x80,0x52,0x09,0xe0,0x5f,0x39,
                                       0x00,0x01,0x29,0x0a,0xc0,0x03,0x5f,0xd6};
    const unsigned char screenBytes[] = {0xff,0xc3,0x03,0xd1,0xeb,0x2b,0x07,0x6d,
                                         0xe9,0x23,0x08,0x6d,0xfc,0x6f,0x09,0xa9};
    const unsigned char layoutBytes[] = {0x03,0x00,0x80,0x52,0x04,0xe0,0x02,0x14};
    if (!matches(gate, "B16@0:8", gateBytes, sizeof(gateBytes)) ||
        !matches(screen, "v24@0:8@16", screenBytes, sizeof(screenBytes)) ||
        !matches(layout, "v20@0:8B16", layoutBytes, sizeof(layoutBytes))) {
        os_log_error(OS_LOG_DEFAULT, "EPUB495: refused unknown activation/layout handler v3");
        return;
    }
    originalScreenChange = (void *)method_setImplementation(screen, (IMP)layoutBeforeScreenChange);
    method_setImplementation(gate, (IMP)useCursor);
    os_log_error(OS_LOG_DEFAULT, "EPUB495: cursor activation v3 enabled build 24B5110a");
}
