/*
 * FanBoost SMC bridge — Swift-friendly wrappers around the smcFanControl
 * SMC code (GPL-2.0, see smc.c). Part of FanBoost, GPL-2.0.
 */
#ifndef FANBOOST_SMC_BRIDGE_H
#define FANBOOST_SMC_BRIDGE_H

/* Pure, side-effect-free: 1 if `key` is exactly 4 bytes (a valid SMC key),
 * else 0. Exported so a check can prove 4-byte accepted / 5-byte rejected
 * without opening the SMC. */
int fb_key_is_valid(const char *key);

/* fb_smc_open must be called once before the others. Read functions return
 * 0 on success, -1 on failure (including a non-4-byte key). */
int fb_smc_open(void);
void fb_smc_close(void);
/* Close and zero the shared SMC connection so a stale/half-open handle can
 * not wedge a subsequent fb_smc_open() during recovery. */
void fb_smc_reset(void);
int fb_read_u8(const char *key, unsigned char *out);
int fb_read_flt(const char *key, float *out);

/* Write `hex` (even-length hex string) to `key`.
 * Returns 0 on success, -1 on transport/argument failure (including a
 * non-4-byte key), otherwise the raw SMC status byte from
 * outputStructure.result (e.g. 0x82 = write rejected, the M3+ "needs Ftst
 * unlock" signal). */
int fb_write_hex(const char *key, const char *hex);

#endif
