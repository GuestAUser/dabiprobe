/*
 * Standalone headless smoke for the pinned, unmodified binding and library.
 *
 * Author: GuestAUser (https://github.com/GuestAUser)
 * Copyright (c) 2026 GuestAUser
 * SPDX-License-Identifier: BSD-2-Clause
 */
module smoke;

import bindbc.glfw;
import glfw_checks;
import std.stdio : writeln;

int main()
{
    if (!checkLibraryVersion() || !checkByValueShim() || !checkLibraryCallback())
    {
        return 1;
    }

    writeln("Imported bindbc.glfw; linked GLFW 3.4.0 without initialization or display");
    writeln("GLFWgamepadstate: size=", GLFWgamepadstate.sizeof, " buttons=",
            GLFWgamepadstate.buttons.sizeof, " axes=", GLFWgamepadstate.axes.sizeof);
    writeln("GLFWvidmode: size=", GLFWvidmode.sizeof, "; six-field by-value shim passed");
    writeln("GLFWerrorfun: callbacks=", callbackCount, " error=", receivedError, " description=",
            receivedDescription[0 .. descriptionLength], "; previous callback restored");

    return 0;
}
