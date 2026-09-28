#!/usr/bin/env python3
# Author: GuestAUser (https://github.com/GuestAUser)
# Copyright (c) 2026 GuestAUser
# SPDX-License-Identifier: BSD-2-Clause

"""Run pinned BindBC-GLFW checks and clearly labeled, disposable regressions."""

import argparse
import difflib
import hashlib
import json
import pathlib
import shlex
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True

from prepare import ARTIFACTS, ROOT, prepare


EXAMPLE = pathlib.Path(__file__).resolve().parent
OUTCOMES = {"checked", "mismatched", "unchecked", "unsupported", "failed_execution"}
MUTATIONS = {
    "injected-byte-signedness": (
        "source/bindbc/glfw/types.d", "ubyte[15] buttons;", "byte[15] buttons;", "buttons",
    ),
    "injected-float-representation": (
        "source/bindbc/glfw/types.d", "float[6] axes;", "int[6] axes;", "axes",
    ),
    "injected-function-return": (
        "source/bindbc/glfw/bindstatic.d",
        "void glfwGetVersion(int* major, int* minor, int* rev);",
        "int glfwGetVersion(int* major, int* minor, int* rev);",
        "glfwGetVersion",
    ),
    "injected-callback-signature": (
        "source/bindbc/glfw/types.d",
        "alias GLFWerrorfun = void function(int,const(char)*);",
        "alias GLFWerrorfun = void function(uint,const(char)*);",
        "glfwSetErrorCallback",
    ),
    "injected-config-layout": (
        "source/bindbc/glfw/types.d",
        "struct GLFWgamepadstate{",
        "version(DabiprobeSeededLayout) enum dabiprobeGamepadAlignment = 1;\n"
        "\telse enum dabiprobeGamepadAlignment = float.alignof;\n"
        "\talign(dabiprobeGamepadAlignment) struct GLFWgamepadstate{\n"
        "\t\talign(dabiprobeGamepadAlignment):",
        "GLFWgamepadstate",
    ),
}


def executable_path(value):
    found = shutil.which(value)

    if found is None:
        raise RuntimeError(f"Executable not found: {value}")

    return str(pathlib.Path(found).resolve())

def run_logged(command, directory, log):
    result = subprocess.run(command, cwd=directory, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    log.write_text("$ " + shlex.join(map(str, command)) + "\n" + result.stdout)

    return result

def require_success(command, directory, log):
    result = run_logged(command, directory, log)

    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}); see {log}")

    return result.stdout

def inject(path, before, after, evidence, occurrences=1):
    original = path.read_text()

    if original.count(before) != occurrences:
        raise RuntimeError(f"Expected {occurrences} pinned mutation targets in {path}")

    modified = original.replace(before, after)
    path.write_text(modified)
    evidence.write_text("".join(difflib.unified_diff(
        original.splitlines(keepends=True), modified.splitlines(keepends=True),
        fromfile=f"unmodified/{path.name}", tofile=f"INJECTED/{path.name}",
    )))

def make_case(suite, name, binding, library, archive, version_flag):
    case = suite / name
    helpers = case / "helpers"
    helpers.mkdir(parents=True)

    for filename in ("glfw_case.h", "glfw_case.c", "glfw_checks.d"):
        shutil.copy2(EXAMPLE / filename, helpers / filename)

    if name in MUTATIONS:
        copied = case / "INJECTED-bindbc-glfw"
        shutil.copytree(binding, copied)
        filename, before, after, label = MUTATIONS[name]
        occurrences = 2 if name == "injected-callback-signature" else 1
        inject(copied / filename, before, after, case / "INJECTED.patch", occurrences)
        (copied / "INJECTED.txt").write_text(
            f"Deliberate dabiprobe regression: {name}. Not an upstream defect.\n"
        )
        binding = copied

    if name == "injected-callback-behavior":
        inject(helpers / "glfw_checks.d", "receivedError = cast(int) code;",
               "receivedError = cast(int) code + 1;", case / "INJECTED.patch")

    manifest = json.loads((EXAMPLE / "manifest.json").read_text())
    manifest["cFlags"] = ["-DGLFW_INCLUDE_NONE", "-I" + str(library / "include"), "-I" + str(helpers)]
    manifest["dFlags"] = [
        version_flag + "BindBC_Static", version_flag + "GLFW_34",
        "-I" + str(binding / "source"), "-I" + str(helpers),
        str(helpers / "glfw_checks.d"), str(archive), "-L-lm", "-L-ldl", "-L-lpthread",
    ]
    manifest["configurations"] = [{"name": "native", "cFlags": [], "dFlags": []}]

    if name == "injected-config-layout":
        manifest["configurations"].append({
            "name": "seeded-layout", "cFlags": [],
            "dFlags": [version_flag + "DabiprobeSeededLayout"],
        })

    path = case / "manifest.json"
    path.write_text(json.dumps(manifest, indent=4) + "\n")

    return path

def check_report(report, expected):
    if report["schemaVersion"] != 1:
        raise RuntimeError("Unexpected report schema version")

    configurations = {entry["name"]: entry for entry in report["configurations"]}

    if set(configurations) != set(expected):
        raise RuntimeError(f"Unexpected configurations: {set(configurations)}")

    for name, mismatch in expected.items():
        entry = configurations[name]
        checks = entry["checks"]
        outcomes = {check["outcome"] for check in checks}

        if not outcomes <= OUTCOMES or outcomes & {"unsupported", "failed_execution"}:
            raise RuntimeError(f"Unexpected outcomes in {name}: {outcomes}")

        if "checked" not in outcomes:
            raise RuntimeError(f"No checks completed in {name}")

        if not any(check["category"] == "measured" and check["outcome"] == "checked"
                   and "glfwWindowShouldClose" in check["label"] for check in checks):
            raise RuntimeError(f"Opaque GLFWwindow pointer contract was not checked in {name}")

        if not any(check["declaration"] == "GLFWwindow <-> GLFWwindow"
                   and check["property"] == "object layout" and check["outcome"] == "unchecked"
                   for check in checks):
            raise RuntimeError(f"Opaque GLFWwindow layout must remain unchecked in {name}")

        mismatches = [check for check in checks if check["outcome"] == "mismatched"]
        behavior = [check for check in checks if check["category"] == "behavior"]
        expected_exit = 1 if mismatch else 0

        if len(behavior) != 3:
            raise RuntimeError(f"Expected all three call checks to be reported in {name}")

        if entry["exitCode"] != expected_exit:
            raise RuntimeError(f"Unexpected configuration exit in {name}: {entry['exitCode']}")

        if mismatch is None:
            if mismatches or any(check["outcome"] != "checked" for check in behavior):
                raise RuntimeError(f"Baseline did not pass all three real calls in {name}")
        elif not any(mismatch in check["label"] for check in mismatches):
            raise RuntimeError(f"Missing expected mismatch {mismatch!r} in {name}")
        elif mismatch == "GLFWerrorfun":
            if len(mismatches) != 1 or mismatches[0]["category"] != "behavior":
                raise RuntimeError("Callback behavior regression unexpectedly failed passive ABI checks")
            if sum(check["outcome"] == "checked" for check in behavior) != 2:
                raise RuntimeError("The other two real calls must pass in the callback behavior case")
        elif any(check["outcome"] != "unchecked" for check in behavior):
            raise RuntimeError(f"Passive mismatch did not gate all three call checks in {name}")

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", default=str(ROOT / ".artifacts/dabiprobe"))
    parser.add_argument("--cc", default="cc")
    parser.add_argument("--dc", default="ldc2")
    parser.add_argument("--prepare-only", action="store_true",
                        help="build dependencies, smoke-test, and write manifests without invoking dabiprobe")
    arguments = parser.parse_args()
    cc = executable_path(arguments.cc)
    dc = executable_path(arguments.dc)
    binding, library, archive = prepare(cc)
    suite = pathlib.Path(tempfile.mkdtemp(prefix="run-", dir=ARTIFACTS))
    shutil.copy2(ARTIFACTS / "provenance.json", suite / "provenance.json")
    compiler_version = require_success([dc, "--version"], ROOT, suite / "d-compiler.log")
    version_flag = "-d-version=" if "LDC" in compiler_version else "-version="
    smoke_object = suite / "glfw_case.o"

    require_success([
        cc, "-std=c11", "-DGLFW_INCLUDE_NONE", "-I" + str(library / "include"),
        "-c", str(EXAMPLE / "glfw_case.c"), "-o", str(smoke_object),
    ], ROOT, suite / "smoke-c-build.log")
    require_success([
        dc, version_flag + "BindBC_Static", version_flag + "GLFW_34",
        "-I" + str(binding / "source"), "-I" + str(EXAMPLE),
        str(EXAMPLE / "smoke.d"), str(EXAMPLE / "glfw_checks.d"),
        str(smoke_object), str(archive), "-L-lm", "-L-ldl", "-L-lpthread",
        "-of=" + str(suite / "smoke"), "-od=" + str(suite),
    ], ROOT, suite / "smoke-d-build.log")
    print(require_success([str(suite / "smoke")], ROOT, suite / "smoke.log"), end="")

    names = ["baseline", *MUTATIONS, "injected-callback-behavior"]
    manifests = {name: make_case(suite, name, binding, library, archive, version_flag) for name in names}
    print(f"Prepared cases: {suite}")

    if arguments.prepare_only:
        return

    executable = executable_path(arguments.executable)
    results = []

    for name, manifest in manifests.items():
        case = manifest.parent
        output = case / "evidence"
        expected = {"native": None}

        if name in MUTATIONS:
            expected = {"native": MUTATIONS[name][3]}

        if name == "injected-config-layout":
            expected = {"native": None, "seeded-layout": "GLFWgamepadstate"}
        elif name == "injected-callback-behavior":
            expected = {"native": "GLFWerrorfun"}

        command = [executable, "--cc", cc, "--dc", dc, "--output", str(output), str(manifest)]
        result = run_logged(command, ROOT, case / "dabiprobe.log")
        expected_exit = 1 if any(expected.values()) else 0

        if result.returncode != expected_exit:
            raise RuntimeError(f"{name}: expected exit {expected_exit}, got {result.returncode}; see {case / 'dabiprobe.log'}")

        report = json.loads((output / "report.json").read_text())
        check_report(report, expected)
        results.append({
            "case": name, "expectedExit": expected_exit, "actualExit": result.returncode,
            "configurations": {entry["name"]: entry["outcomeCounts"] for entry in report["configurations"]},
            "report": str(output / "report.json"),
        })
        print(f"PASS {name}: expected exit {expected_exit}; report outcomes verified")

    summary = {
        "executable": executable,
        "executableSha256": hashlib.sha256(pathlib.Path(executable).read_bytes()).hexdigest(),
        "cc": cc, "dc": dc, "suite": str(suite), "results": results,
    }
    (suite / "summary.json").write_text(json.dumps(summary, indent=4) + "\n")
    print(f"All expected outcomes verified; retained evidence: {suite}")

if __name__ == "__main__":
    main()
