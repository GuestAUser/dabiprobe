/*
 * C aggregate and callback declarations for the linked interop example.
 *
 * Author: GuestAUser (https://github.com/GuestAUser)
 * Copyright (c) 2026 GuestAUser
 * SPDX-License-Identifier: BSD-2-Clause
 */
#ifndef DABIPROBE_INTEROP_API_H
#define DABIPROBE_INTEROP_API_H

#include <stdint.h>

typedef struct AbiPair
{
    int32_t count;
    double weight;
} AbiPair;

typedef int32_t (*AbiCallback)(int32_t);

int32_t abi_add(int32_t left, int32_t right);
AbiPair abi_adjust(AbiPair value, int32_t delta);
int32_t abi_apply(AbiCallback callback, int32_t value);

#endif
