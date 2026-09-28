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
import tempfile
from typing import Any
import unittest


ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "examples" / "packet"


class ProbeIntegrationTests(unittest.TestCase):
    manifest: Any
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

    def write_manifest(self):
        self.manifest_path.write_text(json.dumps(self.manifest))

    def replace_d(self, original, replacement):
        path = self.fixture / "packet.d"
        source = path.read_text()
        self.assertIn(original, source)
        path.write_text(source.replace(original, replacement))

    def run_probe(self, expected, *, cc=None, dc=None):
        environment = dict(os.environ)

        for name in ("TMPDIR", "TMP", "TEMP"):
            environment[name] = str(self.probe_temporary)

        result = subprocess.run(
            [
                str(self.executable),
                "--cc", cc if cc is not None else self.cc,
                "--dc", dc if dc is not None else self.dc,
                str(self.manifest_path),
            ],
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
        self.assertEqual(list(self.probe_temporary.iterdir()), [], "probe scratch was not removed")

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
                self.assertIn("scalar kind", result.stdout)

    def test_same_size_field_signedness_mismatch(self):
        self.replace_d("uint value;", "int value;")
        result = self.run_probe(1)
        self.assertIn("scalar kind", result.stdout)

    def test_function_contracts_and_bidirectional_calls(self):
        self.use_interop()
        result = self.run_probe(0)
        self.assertIn("PASS call aggregate argument and return", result.stdout)
        self.assertIn("PASS call C calls D callback", result.stdout)

    def test_function_mismatch_skips_call_execution(self):
        self.use_interop()
        self.replace_binding("int abi_add(int left", "uint abi_add(int left")
        self.manifest["calls"] = [{"name": "must not run", "d": "this is not valid D code"}]
        self.write_manifest()
        result = self.run_probe(1)
        self.assertIn("SKIP 1 call checks", result.stdout)

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
        self.assertIn("scalar kind", result.stdout)

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
                self.assertIn("SKIP", result.stdout)

    def test_explicit_call_failure(self):
        self.use_interop()
        self.manifest["calls"] = [{"name": "wrong result", "d": "abi_add(-7, 12) == 6"}]
        self.write_manifest()
        result = self.run_probe(1)
        self.assertIn("FAIL call wrong result", result.stdout)

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
            {"functions": [{"c": "abi_add", "d": "abi_add"}]},
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
