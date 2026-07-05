// Callsign hash table for decoding nonstandard-call FT8/FT4 messages
// (<CA0LL> style hashed callsigns), adapted from ft8_lib demo/decode_ft8.c
// (MIT license, Kārlis Goba).
#ifndef _INCLUDE_HASHTABLE_H_
#define _INCLUDE_HASHTABLE_H_

#include <stdint.h>

#include <ft8/message.h>

#ifdef __cplusplus
extern "C"
{
#endif

/// Clear the callsign hash table.
void cft8_hashtable_init(void);

/// Age all entries by one decoding cycle and drop entries older than max_age.
void cft8_hashtable_cleanup(uint8_t max_age);

/// Hash interface for ftx_message_encode/ftx_message_decode backed by the
/// global table. Not thread-safe: callers must serialize access externally.
ftx_callsign_hash_interface_t* cft8_hash_interface(void);

#ifdef __cplusplus
}
#endif

#endif // _INCLUDE_HASHTABLE_H_
