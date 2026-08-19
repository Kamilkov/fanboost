/*
 * FanBoost SMC bridge — Swift-friendly wrappers around the smcFanControl
 * SMC code (GPL-2.0, see smc.c). Part of FanBoost, GPL-2.0.
 */
#include <string.h>
#include <IOKit/IOKitLib.h>
#include "smc.h"
#include "smc_bridge.h"

extern io_connect_t g_conn;

int fb_key_is_valid(const char *key) {
    return (key != NULL && strlen(key) == 4) ? 1 : 0;
}

/* SMC keys are exactly 4 bytes. Reject any other length instead of silently
 * truncating (e.g. a hypothetical "F10Md" must NOT become "F10M"). Returns 0
 * on success, -1 if the key is not exactly 4 characters. */
static int copy_key(UInt32Char_t dst, const char *key) {
    if (!fb_key_is_valid(key)) return -1;
    memcpy(dst, key, 4);
    dst[4] = 0;
    return 0;
}

int fb_smc_open(void) {
    smc_init();
    return g_conn ? 0 : -1;
}

void fb_smc_close(void) { smc_close(); }

void fb_smc_reset(void) {
    if (g_conn) {
        SMCClose(g_conn);
        g_conn = 0;
    }
}

int fb_read_u8(const char *key, unsigned char *out) {
    SMCVal_t val;
    UInt32Char_t k;
    if (copy_key(k, key) != 0) return -1;
    memset(&val, 0, sizeof(val));
    if (SMCReadKey(k, &val) != kIOReturnSuccess || val.dataSize < 1) return -1;
    *out = val.bytes[0];
    return 0;
}

int fb_read_flt(const char *key, float *out) {
    SMCVal_t val;
    UInt32Char_t k;
    if (copy_key(k, key) != 0) return -1;
    memset(&val, 0, sizeof(val));
    if (SMCReadKey(k, &val) != kIOReturnSuccess || val.dataSize != 4) return -1;
    memcpy(out, val.bytes, 4); /* flt keys are IEEE-754 little-endian */
    return 0;
}

/* SMCCall2 is defined non-static in smc.c but not declared in smc.h. */
extern kern_return_t SMCCall2(int index, SMCKeyData_t *inputStructure,
                              SMCKeyData_t *outputStructure, io_connect_t conn);

/* Like SMCWriteKey2, but surfaces outputStructure.result so callers can
 * distinguish SMC rejection codes (0x82 → M3+ Ftst unlock) from success. */
int fb_write_hex(const char *key, const char *hex) {
    SMCVal_t readVal;
    SMCKeyData_t inputStructure, outputStructure;
    UInt32Char_t k;
    size_t i, len;

    if (copy_key(k, key) != 0) return -1;
    len = strlen(hex);
    if (len == 0 || len % 2 != 0 || len / 2 > sizeof(inputStructure.bytes)) return -1;

    /* Key must exist and sizes must match, as in upstream SMCWriteKey2. */
    memset(&readVal, 0, sizeof(readVal));
    if (SMCReadKey(k, &readVal) != kIOReturnSuccess) return -1;
    if (readVal.dataSize != len / 2) return -1;

    memset(&inputStructure, 0, sizeof(inputStructure));
    memset(&outputStructure, 0, sizeof(outputStructure));
    inputStructure.key = _strtoul(k, 4, 16);
    inputStructure.data8 = SMC_CMD_WRITE_BYTES;
    inputStructure.keyInfo.dataSize = (UInt32)(len / 2);
    for (i = 0; i < len / 2; i++) {
        char c[3] = { hex[i * 2], hex[i * 2 + 1], 0 };
        inputStructure.bytes[i] = (unsigned char)strtol(c, NULL, 16);
    }
    if (SMCCall2(KERNEL_INDEX_SMC, &inputStructure, &outputStructure, g_conn)
            != kIOReturnSuccess) return -1;
    return (unsigned char)outputStructure.result; /* 0 = success */
}
