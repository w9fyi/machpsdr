// Callsign hash table adapted from ft8_lib demo/decode_ft8.c
// (MIT license, Kārlis Goba).
#include "hashtable.h"

#include <string.h>

#define CALLSIGN_HASHTABLE_SIZE 256

static struct
{
    char callsign[12]; ///< Up to 11 symbols of callsign + trailing zeros (always filled)
    uint32_t hash;     ///< 8 MSBs contain the age of callsign; 22 LSBs contain hash value
} callsign_hashtable[CALLSIGN_HASHTABLE_SIZE];

void cft8_hashtable_init(void)
{
    memset(callsign_hashtable, 0, sizeof(callsign_hashtable));
}

void cft8_hashtable_cleanup(uint8_t max_age)
{
    for (int idx_hash = 0; idx_hash < CALLSIGN_HASHTABLE_SIZE; ++idx_hash)
    {
        if (callsign_hashtable[idx_hash].callsign[0] != '\0')
        {
            uint8_t age = (uint8_t)(callsign_hashtable[idx_hash].hash >> 24);
            if (age > max_age)
            {
                callsign_hashtable[idx_hash].callsign[0] = '\0';
                callsign_hashtable[idx_hash].hash = 0;
            }
            else
            {
                callsign_hashtable[idx_hash].hash = (((uint32_t)age + 1u) << 24) | (callsign_hashtable[idx_hash].hash & 0x3FFFFFu);
            }
        }
    }
}

static void hashtable_add(const char* callsign, uint32_t hash)
{
    uint16_t hash10 = (hash >> 12) & 0x3FFu;
    int idx_hash = (hash10 * 23) % CALLSIGN_HASHTABLE_SIZE;
    while (callsign_hashtable[idx_hash].callsign[0] != '\0')
    {
        if (((callsign_hashtable[idx_hash].hash & 0x3FFFFFu) == hash) && (0 == strcmp(callsign_hashtable[idx_hash].callsign, callsign)))
        {
            // Duplicate entry: reset age
            callsign_hashtable[idx_hash].hash &= 0x3FFFFFu;
            return;
        }
        idx_hash = (idx_hash + 1) % CALLSIGN_HASHTABLE_SIZE;
    }
    strncpy(callsign_hashtable[idx_hash].callsign, callsign, 11);
    callsign_hashtable[idx_hash].callsign[11] = '\0';
    callsign_hashtable[idx_hash].hash = hash;
}

static bool hashtable_lookup(ftx_callsign_hash_type_t hash_type, uint32_t hash, char* callsign)
{
    uint8_t hash_shift = (hash_type == FTX_CALLSIGN_HASH_10_BITS) ? 12 : (hash_type == FTX_CALLSIGN_HASH_12_BITS ? 10 : 0);
    uint16_t hash10 = (hash >> (12 - hash_shift)) & 0x3FFu;
    int idx_hash = (hash10 * 23) % CALLSIGN_HASHTABLE_SIZE;
    while (callsign_hashtable[idx_hash].callsign[0] != '\0')
    {
        if (((callsign_hashtable[idx_hash].hash & 0x3FFFFFu) >> hash_shift) == hash)
        {
            strcpy(callsign, callsign_hashtable[idx_hash].callsign);
            return true;
        }
        idx_hash = (idx_hash + 1) % CALLSIGN_HASHTABLE_SIZE;
    }
    callsign[0] = '\0';
    return false;
}

static ftx_callsign_hash_interface_t hash_if = {
    .lookup_hash = hashtable_lookup,
    .save_hash = hashtable_add
};

ftx_callsign_hash_interface_t* cft8_hash_interface(void)
{
    return &hash_if;
}
