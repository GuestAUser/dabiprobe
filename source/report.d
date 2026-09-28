/*
 * Scoped verification evidence and standalone reproduction bundles.
 *
 * Records only observed commands and selected checks. Generated sources are
 * retained explicitly; dependencies and arbitrary prebuilt libraries are not
 * certified or silently copied into the evidence bundle.
 *
 * Author: GuestAUser (https://github.com/GuestAUser)
 * Copyright (c) 2026 GuestAUser
 * SPDX-License-Identifier: BSD-2-Clause
 */
module report;

import runner : CommandRecord, createPrivateDirectory, removeWorkspace;
import std.algorithm : all;
import std.ascii : isAlphaNum;
import std.conv : to;
import std.digest.sha : sha256Of;
import std.digest : toHexString;
import std.exception : enforce;
import std.file : mkdir, write;
import std.json : JSONValue;
import std.path : absolutePath, buildPath;
import std.process : environment;
import std.uni : toLower;

enum Outcome
{
    checked,
    mismatched,
    unchecked,
    unsupported,
    failed_execution
}

enum CheckCategory
{
    measured,
    behavior,
    coverage
}

struct CheckResult
{
    string label;
    CheckCategory category;
    Outcome outcome = Outcome.unchecked;
    string cValue;
    string dValue;
    string expected;
    string detail;
    string declaration;
    string property;
    string policy;
    string kind;
    long row = -1;
    string cExpression;
    string dType;
    string unsupportedValue;
    string unsupportedReason;

    JSONValue toJSON() const
    {
        return JSONValue([
            "label": JSONValue(label),
            "category": JSONValue(to!string(category)),
            "outcome": JSONValue(to!string(outcome)),
            "cValue": JSONValue(cValue),
            "dValue": JSONValue(dValue),
            "expected": JSONValue(expected),
            "detail": JSONValue(detail),
            "declaration": JSONValue(declaration),
            "property": JSONValue(property),
            "policy": JSONValue(policy),
            "kind": JSONValue(kind),
            "row": JSONValue(row),
            "cExpression": JSONValue(cExpression),
            "dType": JSONValue(dType),
            "unsupportedValue": JSONValue(unsupportedValue),
            "unsupportedReason": JSONValue(unsupportedReason)
        ]);
    }
}

private struct GeneratedSource
{
    string name;
    string contents;
}

private int mergeExitCode(int current, int additional)
{
    foreach (code; [2, 1, 3])
    {
        if (current == code || additional == code)
        {
            return code;
        }
    }

    return 0;
}

final class ConfigurationReport
{
    string name;
    JSONValue configuration;
    string directory;
    string workspace;
    CheckResult[] checks;
    CommandRecord[] commands;

    private GeneratedSource[] sources;

    this(string name, JSONValue configuration, string directory, string workspace)
    {
        this.name = name;
        this.configuration = configuration;
        this.directory = absolutePath(directory);
        this.workspace = workspace.length ? absolutePath(workspace) : "";
    }

    void addSource(string name, string contents)
    {
        enforce(name.length != 0 && name != "." && name != ".."
                && name.all!(character => isAlphaNum(character) || character == '.' || character == '_'
                    || character == '-'), "generated source requires a plain filename");

        foreach (source; sources)
        {
            enforce(source.name.toLower != name.toLower, "duplicate generated source: " ~ name);
        }

        sources ~= GeneratedSource(name, contents);
    }

    void recordCommand(CommandRecord command)
    {
        command.arguments = command.arguments.dup;
        commands ~= command;
    }

    int exitCode() const
    {
        int result;

        foreach (command; commands)
        {
            if (!command.started || command.status != 0)
            {
                return 2;
            }
        }

        foreach (check; checks)
        {
            bool incomplete = check.outcome == Outcome.unchecked && check.row >= 0
                && (check.category == CheckCategory.measured
                        || check.category == CheckCategory.behavior);

            int code = check.outcome == Outcome.failed_execution ? 2 : check.outcome == Outcome.mismatched
                ? 1 : check.outcome == Outcome.unsupported || incomplete ? 3 : 0;

            result = mergeExitCode(result, code);
        }

        return result;
    }

    JSONValue toJSON(string artifactPrefix = "")
    {
        JSONValue[] results;
        JSONValue[string] counts;

        foreach (outcome; [
            Outcome.checked, Outcome.mismatched, Outcome.unchecked,
            Outcome.unsupported, Outcome.failed_execution
        ])
        {
            counts[to!string(outcome)] = JSONValue(0);
        }

        foreach (check; checks)
        {
            results ~= check.toJSON();

            auto key = to!string(check.outcome);

            counts[key] = JSONValue(counts[key].integer + 1);
        }

        JSONValue[] recordedCommands;
        JSONValue[string] compilers;

        foreach (index, command; commands)
        {
            auto log = artifactPrefix ~ "logs/" ~ to!string(index) ~ ".txt";
            auto value = commandJSON(command, log);

            recordedCommands ~= value;

            if (command.stage == "C compiler identification"
                    || command.stage == "D compiler identification")
            {
                auto language = command.stage[0 .. 1].toLower;

                compilers[language] = value;
            }
        }

        JSONValue[] generatedSources;

        foreach (source; sources)
        {
            generatedSources ~= JSONValue([
                "name": JSONValue(source.name),
                "path": JSONValue(artifactPrefix ~ "sources/" ~ source.name),
                "sha256": JSONValue(toHexString(sha256Of(source.contents)).idup)
            ]);
        }

        return JSONValue([
            "name": JSONValue(name),
            "configuration": configuration,
            "directory": JSONValue(directory),
            "workspace": JSONValue(workspace),
            "exitCode": JSONValue(exitCode()),
            "outcomeCounts": JSONValue(counts),
            "checks": JSONValue(results),
            "commands": JSONValue(recordedCommands),
            "compilers": JSONValue(compilers),
            "sources": JSONValue(generatedSources)
        ]);
    }
}

private JSONValue commandJSON(ref const CommandRecord command, string log)
{
    return JSONValue([
        "arguments": JSONValue(command.arguments),
        "directory": JSONValue(command.directory),
        "stage": JSONValue(command.stage),
        "started": command.started ? JSONValue(true) : JSONValue.init,
        "status": command.started ? JSONValue(command.status) : JSONValue.init,
        "error": JSONValue(command.error),
        "log": JSONValue(log)
    ]);
}

enum environmentNames = [
    "PATH", "CPATH", "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH", "LIBRARY_PATH",
    "LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH",
    "INCLUDE", "LIB", "LIBPATH", "DFLAGS", "LDC_CONFIG", "DMD_CONF"
];

final class EvidenceReport
{
    string manifestPath;
    string manifestText;
    ConfigurationReport[] configurations;

    private JSONValue capturedEnvironment;

    this(string manifestPath, string manifestText)
    {
        this.manifestPath = absolutePath(manifestPath);
        this.manifestText = manifestText;

        JSONValue[string] values;

        foreach (name; environmentNames)
        {
            if (name in environment)
            {
                values[name] = JSONValue(environment.get(name));
            }
        }

        capturedEnvironment = JSONValue(values);
    }

    int exitCode() const
    {
        int result;

        foreach (configuration; configurations)
        {
            result = mergeExitCode(result, configuration.exitCode());
        }

        return result;
    }

    JSONValue toJSON()
    {
        JSONValue[] entries;

        foreach (index, configuration; configurations)
        {
            entries ~= configuration.toJSON("configurations/" ~ to!string(index) ~ "/");
        }

        version (Windows)
        {
            enum host = "windows";
        }
        else
        {
            enum host = "posix";
        }

        return JSONValue([
            "schemaVersion": JSONValue(1),
            "host": JSONValue(host),
            "manifestPath": JSONValue(manifestPath),
            "manifestSnapshot": JSONValue("manifest.json"),
            "manifestSha256": JSONValue(toHexString(sha256Of(manifestText))
                    .idup),
            "exitCode": JSONValue(exitCode()),
            "scope": JSONValue("Partial evidence for selected checks, configurations, compilers, and inputs; "
                    ~ "not comprehensive binding verification or certification of an arbitrary prebuilt library."),
            "environment": capturedEnvironment,
            "environmentAllowlist": JSONValue(environmentNames),
            "environmentPolicy": JSONValue("Only listed build/search/runtime variables are captured. "
                    ~ "Other inherited variables are not recorded. Replay uses its current environment unless "
                    ~ "--recorded-env is selected. Flags, sources, paths, and logs may themselves contain sensitive data."),
            "relocationLimits": JSONValue("Generated sources and private-workspace paths are relocatable. "
                    ~ "Headers, D imports, libraries, response files, compiler installations/configuration, and other "
                    ~ "dependencies remain external. --workdir remaps the original input directory; --cc/--dc replace "
                    ~ "compiler executables. Other absolute paths and embedded linker/response-file paths are unchanged. "
                    ~ "Compatible host ABI and external dependencies are required. Overrides must preserve reflected "
                    ~ "D declarations and target metadata; changed discovery requires fresh probe generation."),
            "configurations": JSONValue(entries)
        ]);
    }

    string writeBundle(string destination)
    {
        destination = absolutePath(destination);

        createPrivateDirectory(destination);

        scope (failure)
        {
            removeWorkspace(destination);
        }

        auto document = toJSON();
        auto configurationRoot = buildPath(destination, "configurations");

        mkdir(configurationRoot);

        string commandLog;

        foreach (index, configuration; configurations)
        {
            auto root = buildPath(configurationRoot, to!string(index));

            mkdir(root);
            mkdir(buildPath(root, "sources"));
            mkdir(buildPath(root, "logs"));

            foreach (source; configuration.sources)
            {
                write(buildPath(root, "sources", source.name), source.contents);
            }

            auto entries = document["configurations"][index]["commands"].array;

            foreach (commandIndex, command; configuration.commands)
            {
                write(buildPath(root, "logs", to!string(commandIndex) ~ ".txt"), command.output);

                auto entry = entries[commandIndex];

                entry["configuration"] = JSONValue(configuration.name);
                entry["index"] = JSONValue(commandIndex);
                commandLog ~= entry.toString() ~ "\n";
            }
        }

        write(buildPath(destination, "manifest.json"), manifestText);
        write(buildPath(destination, "commands.jsonl"), commandLog);
        write(buildPath(destination, "README.txt"), bundleReadme);
        write(buildPath(destination, "replay.py"), replaySource);
        write(buildPath(destination, "report.json"), document.toPrettyString() ~ "\n");

        return destination;
    }

    string persistInWorkspace(ConfigurationReport configuration)
    {
        enforce(configuration.workspace.length != 0,
                "no owned workspace is available for retained evidence");

        auto retained = new EvidenceReport(manifestPath, manifestText);

        retained.capturedEnvironment = capturedEnvironment;
        retained.configurations = [configuration];

        return retained.writeBundle(buildPath(configuration.workspace, "evidence"));
    }
}

private enum bundleReadme = q"README
dabiprobe scoped evidence bundle

Run: python3 replay.py [--config NAME] [--workdir DIR] [--cc PATH] [--dc PATH]
Windows: python replay.py (requires Python 3.13+ for private temporary directories).

The replay script needs Python and the recorded C/D compilers, not dabiprobe.
It rebuilds in fresh private scratch and executes only commands actually recorded.
It never executes previously retained binaries. Each command is a literal argv array,
not a shell string. Successful commands do not imply that all ABI checks passed.
Replay rechecks emitted measurements; non-emitted unsupported/unchecked entries stay
explicit. Exit priorities are 2 execution/input, 1 mismatch, 3 unsupported/incomplete,
0 otherwise. Requested measured/behavior rows without replayed results are incomplete;
coverage-only unchecked notes do not make the run fail. Unsupported predicate values
are interpreted only where the check declares that metadata, never as ordinary data.
An original execution failure that now succeeds but leaves missing checks is still
incomplete evidence (exit 3), not a successful complete rerun of the verification.

report.json contains per-configuration outcomes, exact original argv/cwd, references
to merged stdout/stderr logs, compiler identification commands, generated-source
hashes, the original manifest hash, and effective configuration snapshots.
commands.jsonl is a separate readable command ledger. A null started/status means
the runner did not obtain a completed process result, not proof no process started.

This is partial evidence, not comprehensive binding verification. It cannot certify
that headers match an arbitrary prebuilt binary. Sample calls cover their inputs only.
Compiler reflections, opaque pointers, arrays, and unselected declarations have only
the coverage explicitly reported. Skipped behavior commands cannot be invented by
the replay script; regenerate the bundle to run newly unblocked checks.

This is not a dependency archive. Headers, imports, libraries, compiler config,
response files, and runtime data remain external. --workdir remaps the original
input directory in cwd and plain/-I paths; --cc/--dc replace compiler executables.
Other absolute paths, embedded linker arguments, and response-file contents are not
rewritten. Overrides and changed dependencies can change the ABI being tested.
Compatible host ABI is still required. Original paths remain in report.json.
Replay is not a new-target generator: C predicates use the captured D reflection.
The discovery command must reproduce equivalent parsed metadata before subsequent
commands run. Changed D declarations or target metadata require a fresh dabiprobe
run to regenerate checks; replay stops incomplete with exit 3 instead of testing
stale predicates. Missing or malformed discovery evidence is an execution error.

Only the environmentAllowlist variables are recorded, never the full environment.
Replay inherits its current environment by default. --recorded-env explicitly
restores the recorded allowlisted values, including which were unset. Other variables
remain inherited and can affect execution. Review before sharing: even allowlisted
values, source text, compiler flags, paths, and diagnostics may contain sensitive data.

Trusted input only. Replay executes compilers and generated/imported/linked code,
including constructors. It is not a sandbox and has no subprocess timeout.
README";

private enum replaySource = q"PYTHON
#!/usr/bin/env python3
#
# Replay selected compiler-backed evidence without a dabiprobe installation.
# Author: GuestAUser (https://github.com/GuestAUser)
# Copyright (c) 2026 GuestAUser
# SPDX-License-Identifier: BSD-2-Clause
#

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

def merge_exit(current, additional):
    return next((code for code in (2, 1, 3) if code in (current, additional)), 0)

def remap_path(argument, original, replacement):
    if not original:
        return argument

    for prefix in ("", "-of=", "-od=", "-I"):
        if not argument.startswith(prefix):
            continue

        value = argument[len(prefix):]

        if value == original:
            return prefix + str(replacement)

        if value.startswith(original) and (original.endswith(("/", "\\"))
                or value[len(original):len(original) + 1] in ("/", "\\")):
            suffix = value[len(original):].lstrip("/\\")
            return prefix + str(Path(replacement).joinpath(*re.split(r"[/\\]", suffix)))

    return argument

def measurements(output, count, baseline):
    lines = output.split("\n")

    if len(lines) != count + 1 or lines[-1] != "":
        raise ValueError("probe emitted an unexpected number of measurements")

    values = []

    for index, line in enumerate(lines[:-1]):
        parts = (line[:-1] if line.endswith("\r") else line).split("\t")

        if len(parts) != 3 or parts[:2] != ["dabiprobe", str(index)]:
            raise ValueError(f"malformed measurement at index {index}")

        value = parts[2]

        if baseline and index == 1:
            if value not in ("little", "big"):
                raise ValueError("invalid endianness measurement")
        else:
            if not re.fullmatch(r"0|-?[1-9][0-9]*", value):
                raise ValueError("noncanonical integer measurement")

            number = int(value)

            if not -(1 << 63) <= number < (1 << 64):
                raise ValueError("integer measurement outside the recorded protocol")

        values.append(value)

    return values

def compiler_override(value):
    if value and any(separator in value for separator in ("/", "\\")):
        return str(Path(value).resolve())

    return value

def measurement_outcome(check, c_values, d_values):
    row = check["row"]

    if check.get("unsupportedValue") and c_values[row] == check["unsupportedValue"] and d_values[row] == check["expected"]:
        return "unsupported"

    matches = c_values[row] == d_values[row] and (not check["expected"] or c_values[row] == check["expected"])
    return "checked" if matches else "mismatched"

def discovery_metadata(output):
    prefix = "DABIPROBE_DISCOVERY\t"
    records = [line[len(prefix):].strip() for line in output.split("\n") if line.startswith(prefix)]

    if len(records) != 1:
        raise ValueError("D discovery did not emit exactly one reflection record")

    metadata = json.loads(records[0])

    if not isinstance(metadata, dict):
        raise ValueError("D discovery reflection record must be a JSON object")

    return metadata

def replay_configuration(bundle, configuration, options, document):
    name = configuration["name"]
    checks = configuration["checks"]
    outputs = {}
    result = 0
    failed_stage = ""
    environment = os.environ.copy()
    measured = [check for check in checks if check["category"] == "measured" and check["row"] >= 0]
    behavior = [check for check in checks if check["category"] == "behavior" and check["row"] >= 0]
    measured_count = max((check["row"] for check in measured), default=-1) + 1
    behavior_count = max((check["row"] for check in behavior), default=-1) + 1
    c_values = d_values = call_values = None

    if options.recorded_env:
        for variable in document["environmentAllowlist"]:
            environment.pop(variable, None)

        environment.update(document["environment"])

    with tempfile.TemporaryDirectory(prefix="dabiprobe-replay-") as temporary:
        workspace = Path(temporary)

        for source in configuration["sources"]:
            source_name = source["name"]

            if not re.fullmatch(r"[A-Za-z0-9_.-]+", source_name) or source_name in (".", ".."):
                raise ValueError("invalid generated source filename")

            contents = (bundle / source["path"]).read_bytes()

            if hashlib.sha256(contents).hexdigest().lower() != source["sha256"].lower():
                raise ValueError(f"generated source hash mismatch: {source_name}")

            (workspace / source_name).write_bytes(contents)

        for command in configuration["commands"]:
            stage = command["stage"]
            original_tool = command["arguments"][0]
            arguments = [remap_path(value, configuration["workspace"], workspace)
                         for value in command["arguments"]]
            directory = remap_path(command["directory"], configuration["workspace"], workspace)

            if options.workdir:
                directory = remap_path(directory, configuration["directory"], options.workdir)
                arguments = [remap_path(value, configuration["directory"], options.workdir)
                             for value in arguments]

            c_identity = configuration["compilers"].get("c", {}).get("arguments", [])
            d_identity = configuration["compilers"].get("d", {}).get("arguments", [])

            if options.cc and (stage in ("C compiler identification", "C compilation")
                               or c_identity and original_tool == c_identity[0]):
                arguments[0] = options.cc

            if options.dc and (stage in ("D compiler identification", "D compilation")
                               or d_identity and original_tool == d_identity[0]):
                arguments[0] = options.dc

            is_behavior = stage == "C/D call probe execution" or (stage == "D compilation"
                and any(Path(argument).name == "dabiprobe_calls.d" for argument in arguments))

            if is_behavior and (c_values is None
                    or any(measurement_outcome(check, c_values, d_values) != "checked" for check in measured)
                    or any(check["outcome"] == "unsupported" and check["row"] < 0 for check in checks)):
                print(f"[{name}] unchecked {stage}: passive checks did not establish supported agreement.")
                continue

            print(f"[{name}] {stage}: cwd={directory} argv={json.dumps(arguments)}", flush=True)

            try:
                process = subprocess.run(arguments, cwd=directory, env=environment,
                                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            except OSError as error:
                print(f"failed_execution: {stage}: {error}", file=sys.stderr)
                result = 2
                failed_stage = stage
                break

            output = process.stdout.decode("utf-8", errors="replace")

            if output:
                print(output, end="" if output.endswith("\n") else "\n", flush=True)

            if process.returncode != 0:
                print(f"failed_execution: {stage}: exit {process.returncode}", file=sys.stderr)
                result = 2
                failed_stage = stage
                break

            if stage == "D declaration discovery":
                metadata = discovery_metadata(output)

                if command["status"] != 0:
                    print(f"[{name}] unchecked: original D discovery failed; rerun dabiprobe to regenerate checks.")
                    return 3

                original_output = (bundle / command["log"]).read_text(encoding="utf-8", errors="replace")

                if discovery_metadata(original_output) != metadata:
                    print(f"[{name}] unsupported: D declarations or target changed; rerun dabiprobe to regenerate checks.")
                    return 3

            outputs[stage] = output

            if stage in ("C probe execution", "D probe execution") and "C probe execution" in outputs and "D probe execution" in outputs:
                c_values = measurements(outputs["C probe execution"], measured_count, True)
                d_values = measurements(outputs["D probe execution"], measured_count, True)

            if stage == "C/D call probe execution":
                call_values = measurements(output, behavior_count, False)

        for check in checks:
            row = check["row"]
            category = check["category"]
            original = check["outcome"]
            outcome = original
            detail = check["detail"]

            if category == "measured" and row >= 0 and c_values is not None:
                c_value, d_value = c_values[row], d_values[row]
                outcome = measurement_outcome(check, c_values, d_values)
                detail = f"C={c_value} D={d_value} expected={check['expected']}"

                if outcome == "unsupported":
                    detail += "; " + check["unsupportedReason"]
            elif category == "behavior" and row >= 0 and call_values is not None:
                value = call_values[row]

                if value not in ("0", "1"):
                    raise ValueError("invalid call result")

                outcome = "checked" if value == "1" else "mismatched"
                detail = f"result={value} expected=1"
            elif row >= 0:
                outcome = "unchecked"
                detail = (
                    "No replayed measurement; the recorded command sequence is incomplete or gated. "
                    "Rerun dabiprobe to regenerate checks."
                )
            elif original == "failed_execution":
                outcome = "failed_execution" if failed_stage else "unchecked"
                detail = "Recorded execution failure; no emitted row proves this check now passes."

            if outcome == "mismatched":
                result = merge_exit(result, 1)
            elif outcome == "unsupported":
                result = merge_exit(result, 3)
            elif outcome == "failed_execution":
                result = 2
            elif outcome == "unchecked" and row >= 0 and category in ("measured", "behavior"):
                result = merge_exit(result, 3)

            print(f"[{name}] {outcome} {category} {check['label']}: {detail}")

        if configuration["exitCode"] == 2 and not failed_stage:
            print(f"[{name}] unchecked: recorded execution failure no longer occurs, but later checks were not captured.")
            result = merge_exit(result, 3)

    print(f"[{name}] replay exit={result}; scope remains partial.")
    return result

def main():
    parser = argparse.ArgumentParser(description="Replay a trusted scoped evidence bundle without dabiprobe.")
    parser.add_argument("--config", action="append", help="Replay only this configuration (repeatable).")
    parser.add_argument("--workdir", help="Relocate the original input directory; dependencies remain external.")
    parser.add_argument("--cc", help="Replace recorded C compiler executable.")
    parser.add_argument("--dc", help="Replace recorded D compiler executable.")
    parser.add_argument("--recorded-env", action="store_true", help="Restore only the captured allowlisted variables.")
    options = parser.parse_args()

    if os.name == "nt" and sys.version_info < (3, 13):
        parser.error("Windows replay requires Python 3.13+ for private temporary-directory permissions.")

    options.workdir = str(Path(options.workdir).resolve()) if options.workdir else None
    options.cc = compiler_override(options.cc)
    options.dc = compiler_override(options.dc)
    bundle = Path(__file__).resolve().parent
    document = json.loads((bundle / "report.json").read_text(encoding="utf-8"))

    if document["schemaVersion"] != 1:
        raise ValueError("unsupported evidence schema")

    configurations = document["configurations"]

    if options.config:
        unknown = set(options.config) - {configuration["name"] for configuration in configurations}

        if unknown:
            parser.error("unknown configuration: " + ", ".join(sorted(unknown)))

        configurations = [configuration for configuration in configurations if configuration["name"] in options.config]

    print(document["scope"])
    print("Dependencies remain external. Only recorded commands will run; trusted code only, no sandbox or timeout.")
    print("Environment: " + ("recorded allowlist over current inherited environment." if options.recorded_env
                              else "current inherited environment; recorded allowlist not restored."))

    result = 0

    for configuration in configurations:
        result = merge_exit(result, replay_configuration(bundle, configuration, options, document))

    return result

if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, IndexError, TypeError) as error:
        print(f"failed_execution: {error}", file=sys.stderr)
        sys.exit(2)
PYTHON";
