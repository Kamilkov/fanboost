/*
 * FanBoost SMC bridge — Swift-friendly wrappers around the smcFanControl
 * SMC code (GPL-2.0, see smc.c). Part of FanBoost, GPL-2.0.
 */
#ifndef FANBOOST_SMC_BRIDGE_H
#define FANBOOST_SMC_BRIDGE_H

/* fb_smc_open must be called once before the others. Read functions return
 * 0 on success, -1 on failure. */
int fb_smc_open(void);
void fb_smc_close(void);
int fb_read_u8(const char *key, unsigned char *out);
int fb_read_flt(const char *key, float *out);

/* Write `hex` (even-length hex string) to `key`.
 * Returns 0 on success, -1 on transport/argument failure, otherwise the raw
 * SMC status byte from outputStructure.result (e.g. 0x82 = write rejected,
 * the M3+ "needs Ftst unlock" signal). */
int fb_write_hex(const char *key, const char *hex);

#endif
