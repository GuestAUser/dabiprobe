/*
 * Command-line orchestration and probe-result validation.
 *
 * Compares compiler-reported ABI measurements and runs explicit linked-call
 * checks only after passive checks have matched.
 *
 * Author: GuestAUser (https://github.com/GuestAUser)
 * Copyright (c) 2026 GuestAUser
 * SPDX-License-Identifier: BSD-2-Clause
 */
module app;

import probes : generate, strings;
import runner : compileC, compileD, compilerPath, createWorkspace,
    executablePath, identifyDCompiler, objectPath, removeWorkspace, run;
import std.array : split;
import std.conv : to;
import std.exception : enforce;
import std.file : readText;
import std.json : parseJSON;
import std.path : absolutePath, buildPath, dirName;
import std.stdio : stderr, writeln;

static import std.file;

/*
 * A probe emits one indexed row per requested measurement. Treat unexpected
 * output as a protocol error rather than comparing a partial or shifted result.
 * CRLF is accepted for Windows; the values themselves must remain canonical.
 */
string[] measurements(string output, size_t count, string language, bool baseline = true)
{
    auto lines = output.split("\n");

    enforce(lines.length == count + 1 && lines[$ - 1].length == 0,
            language ~ " probe emitted an unexpected number of measurements");

    string[] values;

    foreach (index, line; lines[0 .. $ - 1])
    {
        if (line.length && line[$ - 1] == '\r')
        {
            line = line[0 .. $ - 1];
        }

        auto parts = line.split("\t");

        enforce(parts.length == 3 && parts[0] == "dabiprobe" && parts[1] == to!string(index),
                language ~ " probe emitted a malformed measurement at index " ~ to!string(index));

        auto value = parts[2];

        enforce(value.length != 0, language ~ " probe emitted an empty measurement");

        /*
         * Endianness is the only textual measurement. Round-trip the remaining
         * values through their full integer domains without merging -1 and
         * ulong.max, accepting leading zeros, or silently overflowing.
         */
        if (baseline && index == 1)
        {
            enforce(value == "little" || value == "big", "invalid endianness measurement");
        }
        else if (value[0] == '-')
        {
            enforce(to!string(to!long(value)) == value, "noncanonical signed measurement");
        }
        else
        {
            enforce(to!string(to!ulong(value)) == value, "noncanonical unsigned measurement");
        }

        values ~= value;
    }

    return values;
}

int verify(string manifestPath, string cc, string dc)
{
    auto manifestFile = absolutePath(manifestPath);
    auto directory = dirName(manifestFile);
    auto manifest = parseJSON(readText(manifestFile));

    auto probe = generate(manifest);
    auto cFlags = strings(manifest, "cFlags");
    auto dFlags = strings(manifest, "dFlags");

    /*
     * Compiler paths belong to the caller's working directory. Input paths and
     * flags belong to the manifest's directory, independent of where it is run.
     */
    cc = compilerPath(cc);
    dc = compilerPath(dc);

    identifyDCompiler(dc, directory);

    auto workspace = createWorkspace();

    scope (exit)
    {
        removeWorkspace(workspace);
    }

    auto cSource = buildPath(workspace, "probe.c");

    /*
     * D infers a module name from its source filename. Keep generated names
     * distinct from common binding modules such as probe and calls.
     */
    auto dSource = buildPath(workspace, "dabiprobe_measurements.d");
    auto cExecutable = executablePath(workspace, "c-probe");
    auto dExecutable = executablePath(workspace, "d-probe");

    std.file.write(cSource, probe.cSource);
    std.file.write(dSource, probe.dSource);

    compileC(cc, cSource, cExecutable, directory, cFlags);

    string[] objects;

    /*
     * Link support code into both D programs: module-level helpers may reference
     * it even before explicit calls run. Trusted constructors can execute here;
     * the later failure gate is not a sandbox for imported or linked code.
     */
    if (probe.cSupportSource.length)
    {
        auto supportSource = buildPath(workspace, "support.c");
        auto supportObject = objectPath(workspace, "support");

        std.file.write(supportSource, probe.cSupportSource);
        compileC(cc, supportSource, supportObject, directory, cFlags, true);

        objects ~= supportObject;
    }

    compileD(dc, dSource, dExecutable, directory, workspace, dFlags, objects);

    auto cOutput = run([cExecutable], directory, "C probe execution");
    auto cValues = measurements(cOutput, probe.labels.length, "C");

    auto dOutput = run([dExecutable], directory, "D probe execution");
    auto dValues = measurements(dOutput, probe.labels.length, "D");

    enforce(probe.expectedValues.length == probe.labels.length, "invalid generated probe metadata");

    size_t failures;

    foreach (index, label; probe.labels)
    {
        auto cValue = cValues[index];
        auto dValue = dValues[index];
        auto expected = probe.expectedValues[index];

        /*
         * Declaration contracts require a successful result on both sides.
         * Two equally wrong signatures must not pass merely because 0 == 0.
         */
        bool matches = cValue == dValue && (expected.length == 0 || cValue == expected);

        failures += !matches;

        writeln(matches ? "PASS " : "FAIL ", label, ": C=", cValue, " D=",
                dValue, expected.length ? " expected=" ~ expected : "");
    }

    size_t checked = probe.labels.length;

    /*
     * Do not exercise a binding after its declarations or layouts have failed.
     * Call probes are separate executables so explicit tests cannot run early.
     */
    if (probe.callLabels.length && failures == 0)
    {
        auto callSource = buildPath(workspace, "dabiprobe_calls.d");
        auto callExecutable = executablePath(workspace, "call-probe");

        std.file.write(callSource, probe.dCallSource);
        compileD(dc, callSource, callExecutable, directory, workspace, dFlags, objects);

        auto output = run([callExecutable], directory, "C/D call probe execution");
        auto values = measurements(output, probe.callLabels.length, "C/D call", false);

        foreach (index, label; probe.callLabels)
        {
            enforce(values[index] == "0" || values[index] == "1", "invalid call result");

            bool matches = values[index] == "1";

            failures += !matches;

            writeln(matches ? "PASS " : "FAIL ", "call ", label, ": result=",
                    values[index], " expected=1");
        }

        checked += values.length;
    }
    else if (probe.callLabels.length)
    {
        writeln("SKIP ", probe.callLabels.length, " call checks: passive ABI checks failed");
    }

    writeln("Summary: ", checked - failures, " passed, ", failures, " failed (",
            checked, " measurements)");

    return failures == 0 ? 0 : 1;
}

void help()
{
    writeln(q"HELP
dabiprobe - Check your D bindings against what the C compiler actually sees!

Usage:
  dabiprobe [--cc PATH] [--dc PATH] MANIFEST.json
  dabiprobe --help

Options:
  --cc PATH   C compiler executable (default: cc; clang on Windows).
  --dc PATH   D compiler executable (default: ldc2). LDC and DMD are accepted.
  --help      Show this help.

Checks:
  Layouts, selected fields, scalar kinds, 64-bit integral values, and explicit
  extern(C) function contracts. Optional linked C/D calls test chosen inputs.

Input:
  A JSON manifest selects the declarations and checks. Relative input paths
  and compiler flags resolve from its directory. Compiler paths are relative
  to your working directory. Both compilers must target the same host ABI.

Examples:
  dabiprobe examples/packet/manifest.json
  dabiprobe --cc clang --dc ldc2 examples/interop/manifest.json

Exit status:
  0  Checks passed (or help displayed).
  1  ABI mismatch or failed call assertion.
  2  Input, compiler, linker, runtime, or probe-output error.

Safety:
  Use trusted inputs only: compilers, imports, and probes can execute code.
  No sandbox or timeout. A pass covers selected checks, not the entire ABI.

Documentation:
  README.md: quick start. docs/dabiprobe.1: schema, requirements, and limits.
HELP");
}

int main(string[] arguments)
{
    try
    {
        version (Windows)
        {
            string cc = "clang";
        }
        else
        {
            string cc = "cc";
        }

        string dc = "ldc2";
        string manifest;

        for (size_t index = 1; index < arguments.length; ++index)
        {
            auto argument = arguments[index];

            if (argument == "--help")
            {
                help();
                return 0;
            }

            if (argument == "--cc" || argument == "--dc")
            {
                enforce(++index < arguments.length, argument ~ " requires a compiler path");

                if (argument == "--cc")
                {
                    cc = arguments[index];
                }
                else
                {
                    dc = arguments[index];
                }

                continue;
            }

            enforce(argument.length != 0 && argument[0] != '-', "unknown option: " ~ argument);
            enforce(manifest.length == 0, "expected exactly one manifest path");

            manifest = argument;
        }

        enforce(manifest.length != 0, "missing manifest path; use --help for usage");

        return verify(manifest, cc, dc);
    }
    catch (Exception error)
    {
        stderr.writeln("ERROR: ", error.msg);
        return 2;
    }
}
