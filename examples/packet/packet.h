/*
 * Reference C layout and integral values for the packet example.
 *
 * Author: GuestAUser (https://github.com/GuestAUser)
 * Copyright (c) 2026 GuestAUser
 * SPDX-License-Identifier: BSD-2-Clause
 */
#ifndef DABIPROBE_PACKET_H
#define DABIPROBE_PACKET_H

#include <stdint.h>

struct Packet
{
    uint8_t tag;
    uint32_t value;
    int16_t samples[3];
};

#define PACKET_LIMIT UINT32_C(4096)
#define PACKET_NEGATIVE (-INT64_C(7))
#define PACKET_MAXIMUM UINT64_MAX

#endif
