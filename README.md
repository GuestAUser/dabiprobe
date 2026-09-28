# dabiprobe

<img src="assets/dabi-probe-logo.png" alt="dabiprobe logo" width="280">

**Check your D bindings against what the C compiler actually sees!**

dabiprobe compiles C and D probes to verify selected bindings against C
declarations. It checks:

- Type sizes/alignment and selected field offsets/sizes.
- Scalar kinds, signedness, and integral values through 64 bits.
- Explicit `extern(C)` function contracts.
- Optional linked C↔D calls, including aggregate returns and callbacks.

## Build and run

Requires a GCC/Clang-compatible C11 driver and LDC or DMD, targeting the same
runnable host ABI. No third-party libraries are needed.

With LDC:

```sh
mkdir -p .artifacts
ldc2 -Isource -of=.artifacts/dabiprobe -od=.artifacts \
  source/app.d source/probes.d source/runner.d

./.artifacts/dabiprobe examples/packet/manifest.json
./.artifacts/dabiprobe --cc clang --dc ldc2 examples/interop/manifest.json
```

Alternatively, `dub build` writes the executable to `.artifacts/`.
Windows executables use the `.exe` suffix.

Use `--cc` and `--dc` to select compiler executables. Defaults are `cc`
(`clang` on Windows) and `ldc2`.

## Choose what to verify

A JSON manifest names the headers, D modules, and checks:

```json
{
  "headers": ["packet.h"],
  "imports": ["packet"],
  "types": [
    {"c": "struct Packet", "d": "Packet", "fields": ["tag", "value"]}
  ],
  "constants": [
    {"c": "PACKET_LIMIT", "d": "packetLimit"}
  ]
}
```

Includes, imports, and relative paths in `cFlags`/`dFlags` resolve from the
manifest's directory. Compiler flags are individual arguments, not shell commands.
Unknown keys and malformed values are errors.

Start with the [packet example](examples/packet/manifest.json) for layout checks,
or [interop example](examples/interop/manifest.json) for function contracts and
real mixed-language calls. Explicit call tests run only after passive checks pass.

| Exit | Meaning |
| --- | --- |
| `0` | Checks passed, or help displayed |
| `1` | ABI mismatch or failed call assertion |
| `2` | Input, compiler, linker, runtime, or probe-output error |

Run `dabiprobe --help` for a command summary. The [manpage](docs/dabiprobe.1)
contains the full schema and reference; view it with `man -l docs/dabiprobe.1`
where available.

## What a pass means

A pass covers the selected checks, target, compiler flags, and test inputs—not
the entire binding. Opaque pointer targets, array elements, unselected fields,
and nested callback signatures are not recursively compared. Sample calls do
not prove every input or calling convention.

**Run only trusted inputs.** Compilation, imports, constructors, and probes can
execute code. There is no sandbox or subprocess timeout; constructors may run
before the explicit-call failure gate.

## Test

```sh
python3 tests/integration.py .artifacts/dabiprobe --cc cc --dc ldc2
```

Requires Python 3 and the compilers above. Tests exercise real matching and
mismatching probes, linked calls, failure paths, and temporary-file cleanup.

## License

[BSD 2-Clause](LICENSE). Copyright (c) 2026
[GuestAUser](https://github.com/GuestAUser).
