/*
 * Reference C implementation used to exercise D-to-C calls and C-to-D callbacks.
 *
 * Author: GuestAUser (https://github.com/GuestAUser)
 * Copyright (c) 2026 GuestAUser
 * SPDX-License-Identifier: BSD-2-Clause
 */
#include "api.h"

int32_t abi_add(int32_t left, int32_t right)
{
    return left + right;
}

AbiPair abi_adjust(AbiPair value, int32_t delta)
{
    value.count += delta;
    value.weight *= 2.0;

    return value;
}

int32_t abi_apply(AbiCallback callback, int32_t value)
{
    return callback(value) + 1;
}
