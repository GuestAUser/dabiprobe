/*
 * Demonstration-owned by-value call using GLFW's original aggregate type.
 *
 * Author: GuestAUser (https://github.com/GuestAUser)
 * Copyright (c) 2026 GuestAUser
 * SPDX-License-Identifier: BSD-2-Clause
 */
#include "glfw_case.h"

GLFWvidmode dabiprobeAdjustVideoMode(GLFWvidmode mode, int increment)
{
    mode.width += increment;
    mode.height -= increment;
    mode.redBits += 1;
    mode.greenBits += 2;
    mode.blueBits += 3;
    mode.refreshRate += increment;

    return mode;
}
