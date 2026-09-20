/* Minimal config for the vendored decode-only build.
 *
 * The upstream autotools/cmake step normally fills this in; only the symbols
 * the decode sources actually reference are defined here. FLOATING_POINT is
 * set through the target's cSettings instead, so it is visible to the headers
 * that check it.
 */
#ifndef CONFIG_H
#define CONFIG_H

/* The library builds as a flat object set inside an SPM target; no dllexport. */
#define EXPORT

/* Y2038-safe time handling is not used by the decoder. */
/* #undef HAVE_INTTYPES_H */

#endif /* CONFIG_H */
