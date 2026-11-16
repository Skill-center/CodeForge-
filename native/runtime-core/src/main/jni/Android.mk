# CodeForge's own (Phase 4 W3; native/PROVENANCE.md): the preload, built by
# ndk-build from native/runtime-core/build.gradle.kts.
#
# libharness-exec.so is t1's harness-exec.c, vendored unchanged: the LD_PRELOAD
# path translator loaded into the runtime's child processes, which rewrites the
# official Termux prefix in interpreter paths before the kernel reads a shebang.
# The exec probe (harness-probe.c) is an executable, not a library, so it is not
# built here: build.gradle.kts compiles it with the NDK's clang.
#
# t1's own Android.mk also builds libtermux from termux.c. That module is never
# built in CodeForge (ADR-0011): the PTY is CodeForge's own, written in Phase 5.
LOCAL_PATH := $(call my-dir)

# Google Play requires 16 KB page support for apps targeting API 35+. NDK r28
# aligns shared objects to 16 KB by default; t1's flags keep it explicit, and
# runtime/check-page-alignment.py checks the APK.
PAGE_ALIGNMENT := -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384

include $(CLEAR_VARS)
LOCAL_MODULE := harness-exec
LOCAL_SRC_FILES := harness-exec.c
LOCAL_LDLIBS := -ldl
LOCAL_LDFLAGS := $(PAGE_ALIGNMENT)
include $(BUILD_SHARED_LIBRARY)
