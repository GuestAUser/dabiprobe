/*
 * D bindings corresponding to the packet example's C declarations.
 *
 * Author: GuestAUser (https://github.com/GuestAUser)
 * Copyright (c) 2026 GuestAUser
 * SPDX-License-Identifier: BSD-2-Clause
 */
module packet;

struct Packet
{
    ubyte tag;
    uint value;
    short[3] samples;
}

enum uint packetLimit = 4096;
enum long packetNegative = -7;
enum ulong packetMaximum = ulong.max;
