/*
 * Real BindBC-GLFW calls and a demonstration-owned aggregate shim.
 *
 * Author: GuestAUser (https://github.com/GuestAUser)
 * Copyright (c) 2026 GuestAUser
 * SPDX-License-Identifier: BSD-2-Clause
 */
module glfw_checks;

import bindbc.glfw;
import std.traits : Parameters;

extern (C) GLFWvidmode dabiprobeAdjustVideoMode(GLFWvidmode mode, int increment) nothrow @nogc;

int callbackCount;
int receivedError;
char[128] receivedDescription;
size_t descriptionLength;

alias ErrorParameters = Parameters!GLFWerrorfun;

extern (C) void captureError(ErrorParameters[0] code, ErrorParameters[1] description) nothrow @nogc
{
    ++callbackCount;
    receivedError = cast(int) code;
    descriptionLength = 0;

    if (description is null)
    {
        return;
    }

    while (descriptionLength < receivedDescription.length && description[descriptionLength] != '\0')
    {
        receivedDescription[descriptionLength] = description[descriptionLength];
        ++descriptionLength;
    }
}

bool checkLibraryVersion()
{
    int major;
    int minor;
    int revision;

    glfwGetVersion(&major, &minor, &revision);

    return major == 3 && minor == 4 && revision == 0;
}

bool checkByValueShim()
{
    auto result = dabiprobeAdjustVideoMode(GLFWvidmode(1920, 1080, 8, 10, 12, 60), 7);

    return result.width == 1927 && result.height == 1073 && result.redBits == 9
        && result.greenBits == 12 && result.blueBits == 15 && result.refreshRate == 67;
}

bool checkLibraryCallback()
{
    callbackCount = 0;
    receivedError = 0;
    descriptionLength = 0;

    auto previous = glfwSetErrorCallback(&captureError);

    glfwInitHint(-1, 0);

    auto removed = glfwSetErrorCallback(previous);
    auto restored = glfwSetErrorCallback(previous);

    return removed == &captureError && restored == previous && callbackCount == 1 && receivedError == GLFW_INVALID_ENUM
        && receivedDescription[0 .. descriptionLength] == "Invalid init hint 0xFFFFFFFF";
}
