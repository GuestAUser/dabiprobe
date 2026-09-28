/*
 * Command-line orchestration and scoped ABI verification.
 *
 * Runs selected checks under named build configurations, separates measurements
 * from explicit calls, and preserves evidence needed to reproduce failures.
 *
 * Author: GuestAUser (https://github.com/GuestAUser)
 * Copyright (c) 2026 GuestAUser
 * SPDX-License-Identifier: BSD-2-Clause
 */
module app;

import discovery : discoverySource, parseDiscovery;
import probes : CheckMetadata, arrayValue, generate, objectKeys, requiredText, strings;
import report : CheckCategory, CheckResult, ConfigurationReport, EvidenceReport, Outcome;
import runner : compileC, compileD, compilerPath, createWorkspace,
    executablePath, identifyDCompiler, objectPath, removeWorkspace, run;
import std.algorithm : canFind;
import std.array : split;
import std.conv : to;
import std.exception : enforce;
import std.file : exists, readText;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : absolutePath, buildPath, dirName;
import std.stdio : stderr, writeln;
import std.string : toUpper;

static import std.file;

struct BuildConfiguration
{
    string name;
    JSONValue manifest;
}

/*
 * Each variant inherits the selected declarations and appends its build flags.
 * Duplicate names and empty configuration lists are errors, not skipped work.
 * Copy the outer JSON object so merging one variant cannot alter another.
 */
BuildConfiguration[] configurations(JSONValue manifest, string selected)
{
    enforce(manifest.type == JSONType.object, "manifest must be an object");

    auto base = manifest.object.dup;
    base.remove("configurations");

    BuildConfiguration[] result;

    if (!("configurations" in manifest.object))
    {
        enforce(selected.length == 0 || selected == "default", "unknown configuration: " ~ selected);
        return [BuildConfiguration("default", JSONValue(base))];
    }

    auto entries = arrayValue(manifest, "configurations");
    enforce(entries.length != 0, "configurations must not be empty");

    bool[string] names;

    foreach (entry; entries)
    {
        objectKeys(entry, ["name", "cFlags", "dFlags"], "configuration");
        auto name = requiredText(entry, "name", "configuration");

        foreach (character; name)
        {
            enforce(character >= ' ' && character != 127,
                    "configuration names must not contain control characters");
        }

        enforce(!(name in names), "duplicate configuration: " ~ name);
        names[name] = true;

        auto effective = JSONValue(base.dup);
        effective["cFlags"] = JSONValue(strings(effective, "cFlags") ~ strings(entry, "cFlags"));
        effective["dFlags"] = JSONValue(strings(effective, "dFlags") ~ strings(entry, "dFlags"));

        if (selected.length == 0 || name == selected)
        {
            result ~= BuildConfiguration(name, effective);
        }
    }

    enforce(result.length != 0, "unknown configuration: " ~ selected);
    return result;
}

/*
 * Framing prevents warnings, constructor output, or truncated programs from
 * becoming apparent measurement agreement. Endianness is the sole text value;
 * all other values must round-trip through their complete integer domains.
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

CheckResult pendingResult(CheckMetadata metadata, string label,
        CheckCategory category, long row = -1)
{
    CheckResult result;
    result.label = label;
    result.declaration = metadata.declaration;
    result.property = metadata.property;
    result.kind = metadata.kind;
    result.policy = metadata.policy;
    result.cExpression = metadata.cExpression;
    result.dType = metadata.dType;
    result.unsupportedValue = metadata.unsupportedValue;
    result.unsupportedReason = metadata.unsupportedReason;
    result.category = category;
    result.outcome = Outcome.unchecked;
    result.detail = "not executed";
    result.row = row;
    return result;
}

void recordFailure(ConfigurationReport configuration, string operation, Exception error)
{
    auto metadata = CheckMetadata(configuration.name, operation, "execution",
            "process completion");
    auto failure = pendingResult(metadata, operation, CheckCategory.coverage);
    failure.outcome = Outcome.failed_execution;
    failure.detail = error.msg;
    configuration.checks ~= failure;

    stderr.writeln("FAILED_EXECUTION [", configuration.name, "] ", operation, ": ", error.msg);
}

void renderConfiguration(ConfigurationReport configuration)
{
    size_t measured;
    size_t exercised;
    size_t mismatched;
    size_t unchecked;
    size_t unsupported;
    size_t failed;

    foreach (check; configuration.checks)
    {
        writeln(toUpper(to!string(check.outcome)), " [", configuration.name,
                "/", to!string(check.category), "] ", check.label,
                check.cValue.length ? ": C=" ~ check.cValue : "", check.dValue.length
                ? " D=" ~ check.dValue : "", check.expected.length
                ? " expected=" ~ check.expected : "", check.detail.length ? ": " ~ check.detail : "");

        if (check.outcome == Outcome.mismatched && check.dType.length)
        {
            writeln("  Reflected D type: ", check.dType,
                    "; native C expression: ", check.cExpression);
        }

        final switch (check.outcome)
        {
        case Outcome.checked:
            measured += check.category == CheckCategory.measured;
            exercised += check.category == CheckCategory.behavior;
            break;
        case Outcome.mismatched:
            ++mismatched;
            break;
        case Outcome.unchecked:
            ++unchecked;
            break;
        case Outcome.unsupported:
            ++unsupported;
            break;
        case Outcome.failed_execution:
            ++failed;
            break;
        }
    }

    writeln("Summary [", configuration.name, "]: measured agreement=",
            measured, ", executed assertions=", exercised, ", mismatched=",
            mismatched, ", unchecked=", unchecked, ", unsupported=",
            unsupported, ", failed_execution=", failed);

    writeln("Scope [", configuration.name, "]: ", unchecked || unsupported || failed
            ? "PARTIAL; " : "SELECTED CHECKS ONLY; ",
            "header measurements are not certification of a prebuilt library.");
}

void executeConfiguration(ConfigurationReport configuration, string cc, string dc)
{
    auto directory = configuration.directory;
    auto workspace = configuration.workspace;
    auto manifest = configuration.configuration;
    string operation = "compiler identification";

    try
    {
        auto cFlags = strings(manifest, "cFlags");
        auto dFlags = strings(manifest, "dFlags");
        auto observer = &configuration.recordCommand;

        run([cc, "--version"], directory, "C compiler identification", false, observer);
        identifyDCompiler(dc, directory, observer);

        /*
         * Compile-time reflection reads the actual imported D declarations.
         * No discovery executable is linked or run, so obtaining metadata does
         * not require calling the library or running module constructors.
         */
        operation = "D declaration discovery";
        auto discoveryFile = buildPath(workspace, "dabiprobe_discovery.d");
        auto discoveryObject = objectPath(workspace, "discovery");
        auto discoveryCode = discoverySource(manifest);

        configuration.addSource("dabiprobe_discovery.d", discoveryCode);
        std.file.write(discoveryFile, discoveryCode);

        auto discoveryOutput = run([dc] ~ dFlags ~ [
            "-c", "-I" ~ directory, "-of=" ~ discoveryObject, "-od=" ~ workspace,
            discoveryFile
        ], directory, operation, false, observer);

        operation = "probe generation";
        auto probe = generate(manifest, parseDiscovery(discoveryOutput));

        enforce(probe.checks.length == probe.labels.length
                && probe.expectedValues.length == probe.labels.length
                && probe.callChecks.length == probe.callLabels.length,
                "invalid generated probe metadata");

        foreach (index, metadata; probe.checks)
        {
            auto result = pendingResult(metadata, probe.labels[index],
                    CheckCategory.measured, index);
            result.expected = probe.expectedValues[index];
            configuration.checks ~= result;
        }

        auto callStart = configuration.checks.length;

        foreach (index, metadata; probe.callChecks)
        {
            auto result = pendingResult(metadata, probe.callLabels[index],
                    CheckCategory.behavior, index);
            result.expected = "1";
            configuration.checks ~= result;
        }

        foreach (pending; probe.pendingChecks)
        {
            auto category = pending.status == "unchecked" ? CheckCategory.coverage
                : pending.check.kind == "call" ? CheckCategory.behavior : CheckCategory.measured;
            auto result = pendingResult(pending.check,
                    pending.check.declaration ~ " " ~ pending.check.property, category);

            enforce(pending.status == "unchecked" || pending.status == "unsupported",
                    "invalid generated pending-check status");

            result.outcome = pending.status == "unsupported" ? Outcome.unsupported
                : Outcome.unchecked;
            result.detail = pending.reason;
            configuration.checks ~= result;
        }

        auto cSource = buildPath(workspace, "probe.c");
        auto dSource = buildPath(workspace, "dabiprobe_measurements.d");
        auto cExecutable = executablePath(workspace, "c-probe");
        auto dExecutable = executablePath(workspace, "d-probe");

        configuration.addSource("probe.c", probe.cSource);
        configuration.addSource("dabiprobe_measurements.d", probe.dSource);

        if (probe.cSupportSource.length)
        {
            configuration.addSource("support.c", probe.cSupportSource);
        }

        if (probe.dCallSource.length)
        {
            configuration.addSource("dabiprobe_calls.d", probe.dCallSource);
        }

        std.file.write(cSource, probe.cSource);
        std.file.write(dSource, probe.dSource);

        operation = "C measurements compilation";
        compileC(cc, cSource, cExecutable, directory, cFlags, false, observer);

        string[] objects;

        if (probe.cSupportSource.length)
        {
            operation = "C support compilation";
            auto supportSource = buildPath(workspace, "support.c");
            auto supportObject = objectPath(workspace, "support");

            std.file.write(supportSource, probe.cSupportSource);
            compileC(cc, supportSource, supportObject, directory, cFlags, true, observer);
            objects ~= supportObject;
        }

        operation = "D measurements compilation";
        compileD(dc, dSource, dExecutable, directory, workspace, dFlags, objects, observer);

        operation = "C measurement execution/decoding";
        auto cValues = measurements(run([cExecutable], directory,
                "C probe execution", false, observer), probe.labels.length, "C");

        foreach (index, value; cValues)
        {
            configuration.checks[index].cValue = value;
        }

        operation = "D measurement execution/decoding";
        auto dValues = measurements(run([dExecutable], directory,
                "D probe execution", false, observer), probe.labels.length, "D");

        foreach (index, value; dValues)
        {
            auto result = &configuration.checks[index];
            result.dValue = value;

            if (result.unsupportedValue.length && result.cValue == result.unsupportedValue
                    && (result.expected.length == 0 || value == result.expected))
            {
                result.outcome = Outcome.unsupported;
                result.detail = result.unsupportedReason;
                continue;
            }

            bool matches = result.cValue == value
                && (result.expected.length == 0 || value == result.expected);

            result.outcome = matches ? Outcome.checked : Outcome.mismatched;
            result.detail = "";
        }

        /*
         * Do not execute an explicit call after a known disagreement or an
         * unsupported requested contract. Unexamined coverage alone does not
         * block calls: they provide separate, deliberately selected evidence.
         */
        bool blocked;

        foreach (check; configuration.checks)
        {
            blocked |= check.outcome == Outcome.mismatched || check.outcome == Outcome.unsupported
                || check.outcome == Outcome.failed_execution || (check.category == CheckCategory.measured
                        && check.row >= 0 && check.outcome == Outcome.unchecked);
        }

        if (blocked)
        {
            foreach (index; 0 .. probe.callLabels.length)
            {
                configuration.checks[callStart + index].detail
                    = "not executed: preceding checks mismatched, are unsupported, or are incomplete";
            }

            return;
        }

        if (probe.callLabels.length == 0)
        {
            return;
        }

        operation = "C/D call compilation";
        auto callSource = buildPath(workspace, "dabiprobe_calls.d");
        auto callExecutable = executablePath(workspace, "call-probe");

        std.file.write(callSource, probe.dCallSource);
        compileD(dc, callSource, callExecutable, directory, workspace, dFlags, objects, observer);

        operation = "C/D call execution/decoding";
        auto values = measurements(run([callExecutable], directory, "C/D call probe execution",
                false, observer), probe.callLabels.length, "C/D call", false);

        foreach (index, value; values)
        {
            enforce(value == "0" || value == "1", "invalid call result");

            auto result = &configuration.checks[callStart + index];
            result.dValue = value;
            result.outcome = value == "1" ? Outcome.checked : Outcome.mismatched;
            result.detail = "";
        }
    }
    catch (Exception error)
    {
        recordFailure(configuration, operation, error);
    }
}

int verify(string manifestPath, string cc, string dc, string selected, string output)
{
    auto manifestFile = absolutePath(manifestPath);
    auto directory = dirName(manifestFile);
    auto manifestText = readText(manifestFile);
    auto selectedConfigurations = configurations(parseJSON(manifestText), selected);

    if (output.length)
    {
        output = absolutePath(output);
        enforce(!exists(output), "output directory already exists: " ~ output);
    }

    cc = compilerPath(cc);
    dc = compilerPath(dc);

    auto evidence = new EvidenceReport(manifestFile, manifestText);
    string[] workspaces;
    string[] retained;

    scope (exit)
    {
        foreach (workspace; workspaces)
        {
            if (!retained.canFind(workspace))
            {
                removeWorkspace(workspace);
            }
        }
    }

    foreach (selection; selectedConfigurations)
    {
        auto configuration = new ConfigurationReport(selection.name,
                selection.manifest, directory, "");
        evidence.configurations ~= configuration;

        try
        {
            configuration.workspace = createWorkspace();
            workspaces ~= configuration.workspace;
            executeConfiguration(configuration, cc, dc);
        }
        catch (Exception error)
        {
            recordFailure(configuration, "workspace creation", error);
        }

    }

    bool exported;
    bool exportFailed;

    if (output.length)
    {
        try
        {
            writeln("Evidence: ", evidence.writeBundle(output));
            exported = true;
        }
        catch (Exception error)
        {
            foreach (configuration; evidence.configurations)
            {
                recordFailure(configuration, "evidence export", error);
            }

            exportFailed = true;
        }
    }

    /*
     * Failed runs retain real source and command evidence by default. Explicit
     * output exports permit normal scratch cleanup. Never overwrite an existing
     * user directory or discard the only reproduction after export fails.
     */
    if (!exported)
    {
        foreach (configuration; evidence.configurations)
        {
            if (!workspaces.canFind(configuration.workspace)
                    || (!exportFailed && configuration.exitCode() == 0))
            {
                continue;
            }

            retained ~= configuration.workspace;

            try
            {
                writeln("Evidence [", configuration.name, "]: ",
                        evidence.persistInWorkspace(configuration));
            }
            catch (Exception error)
            {
                recordFailure(configuration, "evidence export", error);
                stderr.writeln("Probe workspace retained: ", configuration.workspace);
                exportFailed = true;
            }
        }
    }

    foreach (configuration; evidence.configurations)
    {
        renderConfiguration(configuration);
    }

    return exportFailed ? 2 : evidence.exitCode();
}

void help()
{
    writeln(q"HELP
dabiprobe - Check your D bindings against what the C compiler actually sees!

Usage:
  dabiprobe [--cc PATH] [--dc PATH] [--config NAME] [--output DIR] MANIFEST.json
  dabiprobe --help

Options:
  --cc PATH      C compiler executable (default: cc; clang on Windows).
  --dc PATH      D compiler executable (default: ldc2). LDC or DMD.
  --config NAME  Run one named build configuration (default: all).
  --output DIR   Save report, sources, commands, and standalone reproduction.
                DIR must not exist. Failed runs otherwise retain private scratch.
  --help         Show this help.

Checks:
  Independent C measurements of selected layouts, representations, values,
  and function contracts. D reflection can supply fields and signatures.
  Explicit linked calls provide separate evidence for chosen test inputs.

Examples:
  dabiprobe examples/packet/manifest.json
  dabiprobe --config release --output results binding-checks.json

Results:
  Checked, mismatched, unchecked, unsupported, and failed-execution states
  are reported per configuration. Partial coverage is never whole-ABI proof.

Exit status:
  0  No disagreement in selected supported checks (inspect coverage).
  1  Measurement mismatch or failed call assertion.
  2  Input, compiler, linker, runtime, output, or evidence-export error.
  3  A requested check is unsupported or remains incomplete.

Safety:
  Trusted inputs only. Compilation, imports, and probes can execute code.
  No sandbox or timeout. Header agreement does not certify a prebuilt library.

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
        string selected;
        string output;

        for (size_t index = 1; index < arguments.length; ++index)
        {
            auto argument = arguments[index];

            if (argument == "--help")
            {
                help();
                return 0;
            }

            if (["--cc", "--dc", "--config", "--output"].canFind(argument))
            {
                enforce(++index < arguments.length && arguments[index].length != 0,
                        argument ~ " requires a nonempty value");

                switch (argument)
                {
                case "--cc":
                    cc = arguments[index];
                    break;
                case "--dc":
                    dc = arguments[index];
                    break;
                case "--config":
                    selected = arguments[index];
                    break;
                case "--output":
                    output = arguments[index];
                    break;
                default:
                    assert(false);
                }

                continue;
            }

            enforce(argument.length != 0 && argument[0] != '-', "unknown option: " ~ argument);
            enforce(manifest.length == 0, "expected exactly one manifest path");
            manifest = argument;
        }

        enforce(manifest.length != 0, "missing manifest path; use --help for usage");
        return verify(manifest, cc, dc, selected, output);
    }
    catch (Exception error)
    {
        stderr.writeln("FAILED_EXECUTION [input]: ", error.msg);
        return 2;
    }
}
