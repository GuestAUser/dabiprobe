/*
 * D declarations for the interop example's C functions, aggregate, and callback.
 *
 * Author: GuestAUser (https://github.com/GuestAUser)
 * Copyright (c) 2026 GuestAUser
 * SPDX-License-Identifier: BSD-2-Clause
 */
module bindings;

struct AbiPair
{
    int count;
    double weight;
}

extern (C)
{
    alias AbiCallback = int function(int);

    int abi_add(int left, int right) nothrow @nogc;
    AbiPair abi_adjust(AbiPair value, int delta) nothrow @nogc;
    int abi_apply(AbiCallback callback, int value) nothrow @nogc;
}
