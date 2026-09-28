#!/usr/bin/env python3
#
# Compiler-backed integration checks for the public dabiprobe CLI.
#
# Exercises matching and mismatching declarations, linked calls, failure paths,
# and temporary-workspace cleanup with real C and D compilers.
#
# Author: GuestAUser (https://github.com/GuestAUser)
# Copyright (c) 2026 GuestAUser
# SPDX-License-Identifier: BSD-2-Clause
#

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from typing import Any
import unittest


ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "examples" / "packet"


class ProbeIntegrationTests(unittest.TestCase):
    manifest: Any
    last_report: dict[str, Any] | None
    executable = ROOT / ".artifacts" / "dabiprobe"
    cc = "cc"
    dc = "ldc2"

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="dabiprobe tests ")
        self.addCleanup(self.temporary.cleanup)
        self.working = Path(self.temporary.name)
        self.probe_temporary = self.working / "probe scratch"
        self.probe_temporary.mkdir()
        self.fixture = self.working / "manifest with spaces"
        shutil.copytree(FIXTURE, self.fixture)
        self.manifest_path = self.fixture / "manifest.json"
        self.manifest = json.loads(self.manifest_path.read_text())
        self.invocation_count = 0
        self.last_report = None

    def write_manifest(self):
        self.manifest_path.write_text(json.dumps(self.manifest))

    def replace_d(self, original, replacement):
        path = self.fixture / "packet.d"
        source = path.read_text()
        self.assertIn(original, source)
        path.write_text(source.replace(original, replacement))

    def run_probe(self, expected, *, cc=None, dc=None, configuration=None,
                  export=True, env_overrides=None):
        environment = dict(os.environ)

        for name in ("TMPDIR", "TMP", "TEMP"):
            environment[name] = str(self.probe_temporary)

        environment.update(env_overrides or {})
        self.invocation_count += 1
        self.last_evidence = self.working / f"evidence {self.invocation_count}"
        arguments = [
            str(self.executable),
            "--cc", cc if cc is not None else self.cc,
            "--dc", dc if dc is not None else self.dc,
        ]

        if configuration is not None:
            arguments += ["--config", configuration]

        if export:
            arguments += ["--output", str(self.last_evidence)]

        arguments.append(str(self.manifest_path))

        result = subprocess.run(
            arguments,
            cwd=self.working,
            env=environment,
            capture_output=True,
            text=True,
            timeout=30,
        )

        self.assertEqual(
            result.returncode,
            expected,
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
        )
        self.assertTrue(result.stdout.strip() or result.stderr.strip())

        if export or expected == 0:
            self.assertEqual(list(self.probe_temporary.iterdir()), [], "probe scratch was not removed")

        report_path = self.last_evidence / "report.json"
        self.last_report = json.loads(report_path.read_text()) if report_path.exists() else None

        if self.last_report is not None:
            self.assertEqual(self.last_report["schemaVersion"], 1)
            self.assertEqual(self.last_report["exitCode"], expected)

        return result

    def report_data(self):
        report = self.last_report

        if report is None:
            self.fail("expected a structured evidence report")

        return report

    def checks(self, configuration="default"):
        return next(
            item["checks"] for item in self.report_data()["configurations"]
            if item["name"] == configuration
        )

    def run_replay(self, bundle, expected, *arguments):
        environment = dict(os.environ)

        for name in ("TMPDIR", "TMP", "TEMP"):
            environment[name] = str(self.probe_temporary)

        result = subprocess.run(
            [sys.executable, str(bundle / "replay.py"), *arguments],
            cwd=self.working,
            env=environment,
            capture_output=True,
            text=True,
            timeout=60,
        )

        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        self.assertEqual(list(self.probe_temporary.iterdir()), [], "replay scratch was not removed")

        return result

    def use_interop(self):
        self.fixture = self.working / "interop with spaces"
        shutil.copytree(ROOT / "examples" / "interop", self.fixture)
        self.manifest_path = self.fixture / "manifest.json"
        self.manifest = json.loads(self.manifest_path.read_text())

    def replace_binding(self, original, replacement):
        path = self.fixture / "bindings.d"
        source = path.read_text()
        self.assertIn(original, source)
        path.write_text(source.replace(original, replacement))

    def test_help(self):
        result = subprocess.run(
            [str(self.executable), "--help"],
            capture_output=True,
            text=True,
            timeout=10,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--cc", result.stdout)
        self.assertIn("--dc", result.stdout)

    def test_matching_from_unrelated_directory_with_spaces(self):
        self.run_probe(0)

    def test_binding_module_named_probe(self):
        self.replace_d("module packet;", "module probe;")
        (self.fixture / "packet.d").rename(self.fixture / "probe.d")
        self.manifest["imports"] = ["probe"]
        self.write_manifest()

        self.run_probe(0)

    def test_binding_module_named_calls(self):
        self.use_interop()
        self.replace_binding("module bindings;", "module calls;")
        (self.fixture / "bindings.d").rename(self.fixture / "calls.d")
        self.manifest["imports"] = ["calls"]
        self.write_manifest()

        self.run_probe(0)

    def test_reflected_fields_reuse_the_binding(self):
        self.manifest["types"][0]["fields"] = "*"
        self.write_manifest()
        self.run_probe(0)

        for name in ("tag", "value", "samples"):
            self.assertTrue(any(
                f"field {name}" in check["label"]
                and check["kind"] == "representation"
                and check["outcome"] == "checked"
                for check in self.checks()
            ))

    def test_equal_size_array_representations_disagree(self):
        header = self.fixture / "packet.h"
        binding = self.fixture / "packet.d"
        header.write_text(header.read_text() + "\nstruct Samples { float values[2]; };\n")
        binding.write_text(binding.read_text() + "\nstruct Samples { int[2] values; }\n")
        self.manifest["types"] = [{"c": "struct Samples", "d": "Samples", "fields": "*"}]
        self.write_manifest()
        self.run_probe(1)

        mismatches = [check for check in self.checks() if check["outcome"] == "mismatched"]
        self.assertEqual(len(mismatches), 1)
        self.assertEqual(mismatches[0]["property"], "representation")
        self.assertIn("values", mismatches[0]["cExpression"])
        self.assertIn("int[2]", mismatches[0]["dType"])

    def test_const_array_representation_agrees(self):
        header = self.fixture / "packet.h"
        binding = self.fixture / "packet.d"
        header.write_text(header.read_text() + "\nstruct Samples { const int values[2]; };\n")
        binding.write_text(binding.read_text() + "\nstruct Samples { const(int)[2] values; }\n")
        self.manifest["types"] = [{"c": "struct Samples", "d": "Samples", "fields": "*"}]
        self.write_manifest()

        self.run_probe(0)

    def test_inferred_function_contracts_need_only_names(self):
        self.use_interop()
        self.manifest["functions"] = [
            {"c": function["c"], "d": function["d"]}
            for function in self.manifest["functions"]
        ]
        self.write_manifest()
        self.run_probe(0)

        declarations = [check for check in self.checks() if check["kind"] == "declaration"]
        self.assertEqual(len(declarations), 3)
        self.assertTrue(all(check["outcome"] == "checked" for check in declarations))

        self.replace_binding("int abi_add(int left", "float abi_add(int left")
        self.run_probe(1)
        self.assertTrue(any(
            "abi_add" in check["label"] and check["outcome"] == "mismatched"
            and check["kind"] == "declaration"
            for check in self.checks()
        ))

    def test_callback_signature_is_more_than_pointer_size(self):
        self.use_interop()
        self.replace_binding("alias AbiCallback = int function(int);",
                             "alias AbiCallback = uint function(int);")
        self.manifest["types"].append({"c": "AbiCallback", "d": "AbiCallback"})
        self.write_manifest()
        self.run_probe(1)

        self.assertTrue(any(
            "AbiCallback" in check["label"] and check["kind"] == "representation"
            and check["outcome"] == "mismatched"
            for check in self.checks()
        ))
        self.assertTrue(all(
            check["outcome"] == "unchecked" for check in self.checks()
            if check["category"] == "behavior"
        ))

    def test_unspecified_c_parameters_do_not_verify_an_arity(self):
        self.use_interop()
        header = self.fixture / "api.h"
        header.write_text(header.read_text().replace(
            "int32_t abi_add(int32_t left, int32_t right);", "int32_t abi_add();"
        ))
        self.replace_binding("int abi_add(int left, int right)", "int abi_add(int left)")
        self.manifest["calls"] = [{"name": "must remain blocked", "d": "true"}]

        for function in (
            {"c": "abi_add", "d": "abi_add"},
            {
                "c": "abi_add", "d": "abi_add",
                "returns": {"c": "int32_t", "d": "int"},
                "parameters": [{"c": "int32_t", "d": "int"}],
            },
        ):
            with self.subTest(function=function):
                self.manifest["functions"] = [function]
                self.write_manifest()
                self.run_probe(3)
                self.assertTrue(any(
                    check["outcome"] == "unsupported" and "abi_add" in check["label"]
                    for check in self.checks()
                ))
                self.assertTrue(all(
                    check["outcome"] == "unchecked" for check in self.checks()
                    if check["category"] == "behavior"
                ))

    def test_unspecified_nested_callback_parameters_are_unsupported(self):
        self.use_interop()
        header = self.fixture / "api.h"
        header.write_text(header.read_text().replace(
            "typedef int32_t (*AbiCallback)(int32_t);", "typedef int32_t (*AbiCallback)();"
        ) + "\nAbiCallback abi_get_callback(void);\n")
        self.manifest["dSource"] += "\nextern(C) AbiCallback abi_get_callback();"
        self.manifest["calls"] = [{"name": "must remain blocked", "d": "true"}]

        for name in ("abi_apply", "abi_get_callback"):
            with self.subTest(function=name):
                self.manifest["functions"] = [{"c": name, "d": name}]
                self.write_manifest()
                self.run_probe(3)
                self.assertTrue(any(check["outcome"] == "unsupported" for check in self.checks()))

    def test_opaque_handle_mapping_checks_pointers_not_object_layout(self):
        header = self.fixture / "packet.h"
        binding = self.fixture / "packet.d"
        header.write_text(header.read_text()
                          + "\ntypedef struct Handle Handle;\nint inspect_handle(const Handle*);\n")
        binding.write_text(binding.read_text()
                           + "\nstruct Handle;\nextern(C) int inspect_handle(const(Handle)*);\n")
        self.manifest["types"] = [{"c": "Handle", "d": "Handle", "opaque": True}]
        self.manifest["functions"] = [{"c": "inspect_handle", "d": "inspect_handle"}]
        self.write_manifest()
        self.run_probe(0)

        self.assertTrue(any(
            "inspect_handle" in check["label"] and check["outcome"] == "checked"
            for check in self.checks()
        ))
        self.assertTrue(any(
            "Handle" in check["label"] and check["outcome"] == "unchecked"
            for check in self.checks()
        ))
        self.assertFalse(any(
            check["declaration"] == "Handle <-> Handle" and check["kind"] == "layout"
            and check["outcome"] == "checked" for check in self.checks()
        ))

        self.manifest["types"] = []
        self.write_manifest()
        self.run_probe(3)
        self.assertFalse(any(check["outcome"] == "failed_execution" for check in self.checks()))

    def test_opaque_by_value_contract_is_unsupported(self):
        header = self.fixture / "packet.h"
        binding = self.fixture / "packet.d"
        header.write_text(header.read_text()
                          + "\ntypedef struct Handle { int value; } Handle;\nint consume_handle(Handle);\n")
        binding.write_text(binding.read_text()
                           + "\nstruct Handle { int value; }\nextern(C) int consume_handle(Handle);\n")
        self.manifest["types"] = [{"c": "Handle", "d": "Handle", "opaque": True}]
        self.manifest["functions"] = [{"c": "consume_handle", "d": "consume_handle"}]
        self.write_manifest()

        self.run_probe(3)
        self.assertTrue(any(check["outcome"] == "unsupported" for check in self.checks()))
        self.assertFalse(any(check["outcome"] == "failed_execution" for check in self.checks()))

    def test_named_configurations_keep_failures_separate(self):
        self.manifest["configurations"] = [
            {"name": "native"},
            {"name": "packed", "cFlags": ["-fpack-struct=1"]},
        ]
        self.write_manifest()
        result = self.run_probe(1)
        report = self.last_report

        if report is None:
            self.fail("expected configuration evidence")

        native, packed = report["configurations"]
        self.assertEqual((native["exitCode"], packed["exitCode"]), (0, 1))
        self.assertEqual(native["configuration"]["cFlags"], self.manifest["cFlags"])
        self.assertEqual(packed["configuration"]["cFlags"],
                         self.manifest["cFlags"] + ["-fpack-struct=1"])
        self.assertIn("MISMATCHED [packed/measured]", result.stdout)
        self.run_replay(self.last_evidence, 1)
        self.run_replay(self.last_evidence, 0, "--config", "native")

        self.run_probe(0, configuration="native")
        self.assertEqual([item["name"] for item in self.report_data()["configurations"]], ["native"])

    def test_invalid_configuration_selection(self):
        self.run_probe(2, configuration="missing")

        for entries in ([], [{"name": "same"}, {"name": "same"}], [{"name": "bad", "unknown": 1}]):
            with self.subTest(configurations=entries):
                self.manifest["configurations"] = entries
                self.write_manifest()
                self.run_probe(2)

    def test_unselected_members_are_explicitly_unchecked(self):
        self.manifest["types"][0]["fields"] = ["tag"]
        self.write_manifest()
        result = self.run_probe(0)

        self.assertIn("PARTIAL", result.stdout)
        self.assertTrue(any(
            "value" in check["label"] and check["outcome"] == "unchecked"
            for check in self.checks()
        ))
        self.assertTrue(any(
            "samples" in check["label"] and check["outcome"] == "unchecked"
            for check in self.checks()
        ))

    def test_unsupported_requested_contract_is_not_success(self):
        self.manifest["types"] = [{"c": "uint32_t", "d": "shared(uint)"}]
        self.write_manifest()
        result = self.run_probe(3)

        self.assertIn("UNSUPPORTED", result.stdout)
        self.assertTrue(any(check["outcome"] == "unsupported" for check in self.checks()))
        self.assertFalse(any(check["outcome"] == "failed_execution" for check in self.checks()))
        self.run_replay(self.last_evidence, 3)

    def test_success_without_export_removes_scratch(self):
        self.run_probe(0, export=False)

    def test_failure_bundle_replays_after_original_workspace_is_removed(self):
        self.replace_d("uint value;", "int value;")
        self.run_probe(1, export=False)
        workspaces = list(self.probe_temporary.iterdir())
        self.assertEqual(len(workspaces), 1)
        retained = workspaces[0]
        relocated = self.working / "relocated evidence"
        shutil.copytree(retained / "evidence", relocated)

        report = json.loads((relocated / "report.json").read_text())
        self.assertEqual(report["exitCode"], 1)
        self.assertTrue(report["configurations"][0]["commands"])
        self.assertFalse(any(
            command["arguments"][0] == str(self.executable)
            for command in report["configurations"][0]["commands"]
        ))

        shutil.rmtree(retained)
        self.run_replay(relocated, 1)

    def test_replay_rejects_changed_discovery_metadata(self):
        self.run_probe(0)
        captured = self.last_evidence
        self.replace_d("uint value;", "ulong value;")

        result = self.run_replay(captured, 3)
        self.assertIn("regenerat", (result.stdout + result.stderr).lower())

    def test_replay_does_not_pass_newly_unblocked_assertions(self):
        self.use_interop()
        header = self.fixture / "api.h"
        original = header.read_text()
        header.write_text(original.replace("double weight;", "int64_t weight;"))
        self.run_probe(1)
        captured = self.last_evidence
        self.assertIn("dabiprobe_calls.d", [
            source["name"] for source in self.report_data()["configurations"][0]["sources"]
        ])

        header.write_text(original)
        result = self.run_replay(captured, 3)
        self.assertIn("regenerat", (result.stdout + result.stderr).lower())

    def test_replay_of_recovered_build_is_incomplete_not_success(self):
        header = self.fixture / "packet.h"
        original = header.read_text()
        header.write_text("#error deliberate failure before measurement execution\n")
        self.run_probe(2)
        captured = self.last_evidence

        header.write_text(original)
        self.run_replay(captured, 3)

    def test_execution_failure_has_configuration_and_command_evidence(self):
        (self.fixture / "packet.h").write_text("#error deliberate compiler failure\n")
        self.run_probe(2)
        report = self.last_report

        if report is None:
            self.fail("expected failed-execution evidence")

        configuration = report["configurations"][0]
        self.assertEqual(configuration["name"], "default")
        self.assertTrue(any(check["outcome"] == "failed_execution" for check in configuration["checks"]))
        self.assertTrue(any(command["status"] for command in configuration["commands"]))
        self.assertTrue(configuration["sources"])
        self.run_replay(self.last_evidence, 2)

    def test_workspace_creation_failure_preserves_the_project(self):
        marker = self.working / "not a directory"
        marker.write_text("preserve this file")

        self.run_probe(2, env_overrides={name: str(marker) for name in ("TMPDIR", "TMP", "TEMP")})
        self.assertEqual(marker.read_text(), "preserve this file")
        self.assertTrue(self.manifest_path.exists())
        self.assertTrue(any(check["outcome"] == "failed_execution" for check in self.checks()))

    def test_existing_evidence_directory_is_not_overwritten(self):
        destination = self.working / "existing evidence"
        destination.mkdir()
        marker = destination / "sentinel"
        marker.write_text("keep")
        result = subprocess.run(
            [str(self.executable), "--output", str(destination), str(self.manifest_path)],
            cwd=self.working, capture_output=True, text=True, timeout=10,
        )

        self.assertEqual(result.returncode, 2)
        self.assertEqual(marker.read_text(), "keep")
        self.assertEqual(list(destination.iterdir()), [marker])

    def test_export_failure_is_retained_as_an_operational_error(self):
        parent = self.working / "blocked output parent"
        parent.write_text("preserve")
        environment = dict(os.environ)

        for name in ("TMPDIR", "TMP", "TEMP"):
            environment[name] = str(self.probe_temporary)

        result = subprocess.run(
            [str(self.executable), "--cc", self.cc, "--dc", self.dc,
             "--output", str(parent / "evidence"), str(self.manifest_path)],
            cwd=self.working, env=environment, capture_output=True, text=True, timeout=30,
        )

        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(parent.read_text(), "preserve")
        workspaces = list(self.probe_temporary.iterdir())
        self.assertEqual(len(workspaces), 1)
        retained = workspaces[0]
        report = json.loads((retained / "evidence" / "report.json").read_text())
        self.assertEqual(report["exitCode"], 2)
        self.assertTrue(any(
            check["outcome"] == "failed_execution" and check["property"] == "evidence export"
            for check in report["configurations"][0]["checks"]
        ))

        shutil.rmtree(retained)

    def test_types_only(self):
        del self.manifest["constants"]
        self.write_manifest()
        self.run_probe(0)

    def test_constants_only(self):
        del self.manifest["types"]
        self.write_manifest()
        self.run_probe(0)

    def test_raw_pointer_and_array_types(self):
        self.manifest["types"] = [
            {"c": "void *", "d": "void*"},
            {"c": "uint32_t[3]", "d": "uint[3]"},
        ]
        del self.manifest["constants"]
        self.write_manifest()
        self.run_probe(0)

    def test_unsigned_constant_with_strict_warnings(self):
        header = self.fixture / "packet.h"
        header.write_text(
            header.read_text()
            + "\nstatic const uint64_t packet_unsigned_value = UINT64_MAX;\n"
        )
        self.manifest["cFlags"] += ["-Wall", "-Wextra", "-Werror"]
        self.manifest["constants"] = [
            {"c": "packet_unsigned_value", "d": "packetMaximum"}
        ]
        self.write_manifest()
        self.run_probe(0)

    def test_renamed_field(self):
        self.replace_d("ubyte tag;", "ubyte renamedTag;")
        self.manifest["types"][0]["fields"][0] = {"c": "tag", "d": "renamedTag"}
        self.write_manifest()
        self.run_probe(0)

    def test_wrong_field_offset(self):
        self.replace_d(
            "ubyte tag;\n    uint value;\n    short[3] samples;",
            "short[3] samples;\n    uint value;\n    ubyte tag;",
        )
        self.run_probe(1)

    def test_wrong_type_and_field_size(self):
        self.replace_d("uint value;", "ulong value;")
        self.run_probe(1)

    def test_wrong_constant(self):
        self.replace_d("packetLimit = 4096", "packetLimit = 4097")
        self.run_probe(1)

    def test_negative_one_is_not_unsigned_maximum(self):
        self.manifest["constants"] = [{"c": "(-1)", "d": "packetMaximum"}]
        self.write_manifest()
        self.run_probe(1)

    def test_integral_expression_is_evaluated_once(self):
        header = self.fixture / "packet.h"
        header.write_text(
            header.read_text()
            + "\nstatic inline int next_value(void) { static int value; return ++value; }\n"
        )
        self.manifest["dSource"] = "int counter; int nextValue() { return ++counter; }"
        self.manifest["constants"] = [{"c": "next_value()", "d": "nextValue()"}]
        self.write_manifest()

        result = self.run_probe(0)
        self.assertIn("C=1 D=1", result.stdout)

    def test_same_size_scalar_kind_mismatches(self):
        for c_type, d_type in (("uint32_t", "int"), ("int32_t", "float"), ("_Bool", "ubyte")):
            with self.subTest(c=c_type, d=d_type):
                self.manifest["types"] = [{"c": c_type, "d": d_type}]
                self.write_manifest()
                result = self.run_probe(1)
                self.assertIn("representation", result.stdout)

    def test_same_size_field_signedness_mismatch(self):
        self.replace_d("uint value;", "int value;")
        result = self.run_probe(1)
        self.assertIn("representation", result.stdout)

    def test_function_contracts_and_bidirectional_calls(self):
        self.use_interop()
        self.run_probe(0)
        behavior = [check for check in self.checks() if check["category"] == "behavior"]

        self.assertEqual(len(behavior), 3)
        self.assertTrue(all(check["outcome"] == "checked" for check in behavior))

    def test_function_mismatch_skips_call_execution(self):
        self.use_interop()
        self.replace_binding("int abi_add(int left", "uint abi_add(int left")
        self.manifest["calls"] = [{"name": "must not run", "d": "this is not valid D code"}]
        self.write_manifest()
        result = self.run_probe(1)
        self.assertIn("not executed: preceding checks", result.stdout)

    def test_both_function_contracts_wrong_cannot_pass(self):
        self.use_interop()
        self.manifest["functions"][0]["returns"] = {"c": "int64_t", "d": "long"}
        self.write_manifest()
        result = self.run_probe(1)
        self.assertIn("C=0 D=0 expected=1", result.stdout)

    def test_function_contract_pairs_must_agree(self):
        self.use_interop()
        self.replace_binding("int abi_add(int left", "float abi_add(int left")
        self.manifest["functions"][0]["returns"]["d"] = "float"
        self.write_manifest()
        result = self.run_probe(1)
        self.assertIn("representation", result.stdout)

    def test_wrong_linkage_and_ref_parameters(self):
        self.use_interop()
        path = self.fixture / "bindings.d"
        original = path.read_text()
        for changed in (
            original.replace("extern (C)", "extern (D)"),
            original.replace("int left", "ref int left"),
        ):
            with self.subTest(binding=changed):
                path.write_text(changed)
                result = self.run_probe(1)
                self.assertIn("not executed: preceding checks", result.stdout)

    def test_explicit_call_failure(self):
        self.use_interop()
        self.manifest["calls"] = [{"name": "wrong result", "d": "abi_add(-7, 12) == 6"}]
        self.write_manifest()
        result = self.run_probe(1)
        self.assertIn("MISMATCHED [default/behavior]", result.stdout)
        self.assertIn("wrong result", result.stdout)

    def test_calls_only(self):
        self.use_interop()
        del self.manifest["types"]
        del self.manifest["functions"]
        self.write_manifest()
        self.run_probe(0)

    def test_call_requires_boolean(self):
        self.use_interop()
        self.manifest["calls"] = [{"name": "not an assertion", "d": "abi_add(1, 2)"}]
        self.write_manifest()
        self.run_probe(2)

    def test_call_process_failure(self):
        self.use_interop()
        self.manifest["calls"] = [{
            "name": "exit",
            "d": "(() { import core.stdc.stdlib : exit; exit(7); return true; })()",
        }]
        self.write_manifest()
        result = self.run_probe(2)
        self.assertIn("exit 7", result.stderr)

    def test_missing_interop_symbol(self):
        self.use_interop()
        del self.manifest["cSource"]
        self.write_manifest()
        self.run_probe(2)

    def test_unexpected_probe_output_is_error(self):
        self.manifest["dSource"] = (
            'shared static this() { import std.stdio : writeln; writeln("unexpected output"); }'
        )
        self.write_manifest()
        result = self.run_probe(2)
        self.assertIn("unexpected number of measurements", result.stderr)

    def test_void_function_contract_and_call(self):
        self.use_interop()
        header = self.fixture / "api.h"
        header.write_text(header.read_text() + "\nvoid abi_ping(void);\n")
        self.manifest["cSource"] += "\nvoid abi_ping(void) {}"
        self.manifest["dSource"] += "\nextern(C) void abi_ping() nothrow @nogc;"
        self.manifest["functions"] = [{
            "c": "abi_ping", "d": "abi_ping",
            "returns": {"c": "void", "d": "void"}, "parameters": [],
        }]
        self.manifest["calls"] = [{
            "name": "void return", "d": "(() { abi_ping(); return true; })()",
        }]
        self.write_manifest()
        self.run_probe(0)

    def test_variadic_contract_match_and_mismatch(self):
        self.use_interop()
        header = self.fixture / "api.h"
        header.write_text(header.read_text() + "\nint abi_variadic(int count, ...);\n")
        self.manifest["dSource"] += "\nextern(C) int abi_variadic(int count, ...) nothrow @nogc;"
        self.manifest["functions"] = [{
            "c": "abi_variadic", "d": "abi_variadic",
            "returns": {"c": "int", "d": "int"},
            "parameters": [{"c": "int", "d": "int"}], "variadic": True,
        }]
        self.manifest["calls"] = []
        self.write_manifest()
        self.run_probe(0)

        self.manifest["functions"][0]["variadic"] = False
        self.write_manifest()
        self.run_probe(1)

    def test_floating_constant_is_not_silently_truncated(self):
        self.manifest["constants"] = [{"c": "1.5", "d": "1.5"}]
        self.write_manifest()
        self.run_probe(2)

    def test_invalid_new_schema(self):
        self.use_interop()
        original = self.manifest.copy()
        for patch in (
            {"functions": [{"c": "abi_add", "d": "abi_add", "returns": {"c": "int", "d": "int"}}]},
            {"functions": [dict(original["functions"][0], variadic="yes")]},
            {"calls": [{"name": "missing expression"}]},
            {"calls": [{"name": "", "d": "true"}]},
            {"cSource": 42},
        ):
            with self.subTest(patch=patch):
                self.manifest = dict(original, **patch)
                self.write_manifest()
                self.run_probe(2)

    def test_malformed_json(self):
        self.manifest_path.write_text('{"headers": [')
        self.run_probe(2)

    def test_invalid_schema(self):
        invalid_manifests = [
            [],
            {},
            {"headers": [], "imports": [], "types": [], "constants": []},
            dict(self.manifest, unknownKey=True),
            dict(self.manifest, headers="packet.h"),
            dict(self.manifest, cFlags=[42]),
            dict(self.manifest, types=[{"c": "struct Packet"}]),
        ]

        for manifest in invalid_manifests:
            with self.subTest(manifest=manifest):
                self.manifest = manifest
                self.write_manifest()
                self.run_probe(2)

    def test_missing_manifest(self):
        self.manifest_path.unlink()
        self.run_probe(2)

    def test_missing_c_compiler(self):
        self.run_probe(2, cc=str(self.working / "missing C compiler"))

    def test_missing_d_compiler(self):
        self.run_probe(2, dc=str(self.working / "missing D compiler"))

    def test_missing_header(self):
        (self.fixture / "packet.h").unlink()
        self.run_probe(2)

    def test_missing_import(self):
        (self.fixture / "packet.d").unlink()
        self.run_probe(2)

    def test_c_compilation_failure(self):
        (self.fixture / "packet.h").write_text("#error deliberate C fixture failure\n")
        self.run_probe(2)

    def test_d_compilation_failure(self):
        self.replace_d("uint value;", "this is not a D declaration;")
        self.run_probe(2)

def main():
    parser = argparse.ArgumentParser(description="Run dabiprobe native integration checks.")
    parser.add_argument(
        "executable", nargs="?", type=Path, default=ROOT / ".artifacts" / "dabiprobe"
    )
    parser.add_argument("--cc", default=os.environ.get("DABIPROBE_CC", "cc"))
    parser.add_argument("--dc", default=os.environ.get("DABIPROBE_DC", "ldc2"))
    args = parser.parse_args()

    ProbeIntegrationTests.executable = args.executable.resolve()
    ProbeIntegrationTests.cc = args.cc
    ProbeIntegrationTests.dc = args.dc
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(ProbeIntegrationTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1

if __name__ == "__main__":
    raise SystemExit(main())
