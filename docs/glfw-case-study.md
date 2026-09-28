# A Maintainer Check Against Real BindBC-GLFW

This example compares selected declarations from an actual D binding with an
actual C header, then exercises the matching locally built library. It does not
replace either side with handwritten copies. Its negative cases deliberately
inject regressions into disposable copies; they are **not upstream bug reports**.

## Pinned Inputs

| Source | Revision | License retained in extracted source |
| --- | --- | --- |
| [BindBC/bindbc-glfw](https://github.com/BindBC/bindbc-glfw) | `76a8ded72aa5a6f9b275b4df0f7046a5dceb8cb6` | `LICENSE_1_0.txt`, Boost Software License 1.0 |
| [glfw/glfw](https://github.com/glfw/glfw) | `7b6aead9fb88b3623e3b3725ebb42670cbe4c579`, GLFW 3.4 | `LICENSE.md`, zlib/libpng license |

The preparation script downloads official GitHub source archives and requires
these SHA-256 digests before extraction:

```text
BindBC: c83e9dcfa21a0a91007dc8288ae5897509a280044e38db5fe74b803d64546770
GLFW:   169d49096e339caabbc12e1762273c5cb9130a535a282ba46cf5c14ab6e55694
```

Downloads, complete upstream sources, licenses, build logs, and the resulting
`libglfw3.a` stay in `.artifacts/maintainer/glfw/`. Nothing is installed globally.
The example-owned C, D, and Python files use the repository's BSD-2-Clause
license; upstream source headers and licenses remain unchanged in pristine
copies and are preserved in injected copies.

Each preparation replaces only the two known pinned source directories before
extracting the verified archives again. Symlinked source directories are
rejected. This removes stale files, including D `.di` files that could otherwise
shadow a pinned `.d` module. Cached downloads and the separate CMake build
directory are reused.

## Run It

This runner targets a native Linux host with Python 3.12+, CMake, Ninja, a
GCC/Clang-compatible C compiler, and LDC or DMD. Both compilers must target the
same runnable ABI. The first run needs network access for the pinned archives;
subsequent runs recheck and reuse them. No installed GLFW, OpenGL development
headers, display server, window, or GPU is required.

From the repository root, build the current CLI and run the case suite:

```sh
mkdir -p .artifacts
ldc2 -Isource -of=.artifacts/dabiprobe -od=.artifacts \
  source/app.d source/probes.d source/runner.d source/discovery.d source/report.d

python3 examples/glfw/run.py \
  --executable .artifacts/dabiprobe --cc cc --dc ldc2
```

Use `--dc dmd` to run the same checks with DMD. Explicit compiler paths such as
`--dc /path/to/ldc2` also work.

For dependency preparation and an independent binding smoke before a CLI build:

```sh
python3 examples/glfw/run.py --dc ldc2 --prepare-only
```

The suite exits successfully only when the baseline passes and every injected
case returns its expected result. An individual negative CLI invocation exits
`1`; the suite treats that as an expected detection, not as a successful ABI
comparison. Compiler, linker, runtime, unsupported-surface, or unexpected
report results fail the suite.

The preparation and runner scripts pin/build these dependencies and manufacture
the demonstration's regressions. An existing package does not need to adopt
that infrastructure: add selectors and relevant call assertions, then use its
existing include, import, version, and link flags.

## Build Context and Selected Surface

GLFW is built as a static library with `GLFW_BUILD_X11`, `GLFW_BUILD_WAYLAND`,
`GLFW_BUILD_EXAMPLES`, `GLFW_BUILD_TESTS`, `GLFW_BUILD_DOCS`, and `GLFW_INSTALL`
all disabled. On Linux this leaves its null platform. C probes define
`GLFW_INCLUDE_NONE`. D imports `bindbc.glfw` from the pinned binding's `source/`
directory, using `BindBC_Static` and `GLFW_34`. The runner chooses LDC's
`-d-version=` or DMD's `-version=` spelling. Static mode does not need
`bindbc-loader`.

The reusable [selection manifest](../examples/glfw/manifest.json) names:

- `GLFWgamepadstate`, with its byte button array and floating-point axes array.
- `GLFWvidmode`, with its six integer fields.
- `GLFWwindow` as an opaque handle, without requesting its layout.
- `glfwGetVersion`, `glfwSetErrorCallback`, `glfwInitHint`, and
  `glfwWindowShouldClose`.
- Four version/error constants and a clearly demonstration-owned by-value shim.

`fields: "*"` discovers the selected aggregates' D fields, and name-only
function entries derive the D function contract. C compiler checks compare the
corresponding declarations. The manifest does not repeat the eight upstream
field declarations or manually transcribe the four GLFW function signatures.
Selecting the relevant names and writing meaningful behavioral assertions
remain maintainer responsibilities.

The `opaque: true` entry supplies the C/D name correspondence needed to compare
the `GLFWwindow*` parameter of `glfwWindowShouldClose`. Its inferred function
contract is checked; the opaque pointee's size, alignment, fields, and behavior
are not. The report explicitly leaves opaque layout `unchecked`. This function
is never called here: no window is created and no display is needed.

The runner adds concrete include, import, library, and helper paths to a
per-case manifest. The selection file alone is intentionally not a complete
machine-specific build configuration. Each generated manifest can be rerun
directly with the same compilers.

## Real Calls, Not Only Layout

The standalone smoke and the CLI's three call assertions check:

1. `glfwGetVersion` reports the linked library's version as `3.4.0`.
2. `dabiprobeAdjustVideoMode` accepts and returns `GLFWvidmode` by value and
   produces the expected result in all six fields. This function is owned by
   this demonstration, **not an API that GLFW provides**. Its C side includes
   the real GLFW header; its D side uses the imported binding type.
3. `glfwSetErrorCallback` registers a real `GLFWerrorfun`. Calling
   `glfwInitHint(-1, 0)` makes the actual library invoke it once with
   `GLFW_INVALID_ENUM` (`65539`) and `Invalid init hint 0xFFFFFFFF`. The callback
   copies the description while it is valid. The test verifies removal of its
   handler and restoration of the previous callback.

The handler derives its parameter types from `Parameters!GLFWerrorfun`; it does
not maintain a separate handwritten callback signature. This also lets the
callback-signature injection reach ABI comparison instead of failing early
because the test handler's declaration disagrees with the injected binding.

None of these calls initializes GLFW or touches a display. The callback
assertion covers both its observed invocation and handler restoration, rather
than merely assigning a function pointer of the expected type.

## Baseline and Injected Regressions

| Case | Deliberate change | Expected CLI result |
| --- | --- | --- |
| `baseline` | None; pinned upstream declarations | `0`, selected checks and all three calls checked |
| `injected-byte-signedness` | `ubyte[15] buttons` becomes `byte[15] buttons` | `1`, array element signedness mismatch despite identical size/offset |
| `injected-float-representation` | `float[6] axes` becomes `int[6] axes` | `1`, array element representation mismatch despite identical size/offset |
| `injected-function-return` | `glfwGetVersion` return changes from `void` to `int` | `1`, inferred function contract mismatch |
| `injected-callback-signature` | `GLFWerrorfun` error parameter changes from `int` to `uint` | `1`, nested callback contract mismatch in `glfwSetErrorCallback`, with pointer size unchanged |
| `injected-config-layout` | Packing enabled only by `DabiprobeSeededLayout` | `native` configuration passes; `seeded-layout` mismatches; combined exit `1` |
| `injected-callback-behavior` | Demonstration callback stores `code + 1` | `1`, passive ABI checks pass, actual callback behavior assertion fails |

The five declaration/configuration changes occur in separately copied binding
trees. The callback change occurs only in a copied demonstration helper. Each
case retains an `INJECTED.patch`; copied binding trees also have `INJECTED.txt`.
Original archives and extracted upstream sources are not patched.

The configuration case uses the same declarations and manifest for both named
configurations. Only the extra D version flag enables packing. To isolate one
configuration, use the generated case path printed by the runner:

```sh
.artifacts/dabiprobe --cc cc --dc ldc2 --config native \
  --output /tmp/glfw-native-evidence \
  .artifacts/maintainer/glfw/run-REPLACE/injected-config-layout/manifest.json
```

Use a new output directory for each CLI invocation. Selecting `seeded-layout`
instead returns `1`. Passive mismatches prevent all three explicit calls from
running; the report marks those call checks `unchecked`. In the callback
behavior case, passive checks match, so the real call runs and is marked
`mismatched` rather than being skipped.

## Observed Diagnostic

The complete seven-case suite passed its expected-result assertions on native
x86-64 Linux with GCC 16.2.1 paired with LDC 1.43.0 and DMD 2.113.0. Each
baseline reported 39 matching passive measurements, three passing call
assertions, and eight explicitly `unchecked` coverage items. Those remaining
items include opaque layout, C-only member completeness, and general function
behavior beyond the selected call assertions. The result remains `PARTIAL`.

The injected signed-byte array produced this actual diagnostic:

```text
MISMATCHED [native/measured] GLFWgamepadstate <-> GLFWgamepadstate field buttons <-> buttons representation: C=0 D=1 expected=1
```

Its `report.json` entry includes these typed diagnostic fields:

```json
{
    "category": "measured",
    "declaration": "GLFWgamepadstate <-> GLFWgamepadstate field buttons <-> buttons",
    "property": "representation",
    "dType": "byte[15]",
    "cExpression": "&(((GLFWgamepadstate*)0)->buttons)",
    "outcome": "mismatched",
    "cValue": "0",
    "dValue": "1",
    "expected": "1"
}
```

Here `0` and `1` are contract-test results, not button values. The C compiler
rejects compatibility with the reflected signed-byte array even though the
array length, size, and field offset still match. The three explicit call
assertions are consequently `unchecked`, and the CLI exits `1`.

## Evidence and Interpretation

Each suite creates a new `run-*` directory and prints its location. It retains:

- Source pins, archive hashes, build configuration, and the built archive hash
  in `provenance.json`.
- Compiler identity, smoke compilation commands, and the real smoke output.
- Generated manifests, copied helpers, and precise injected patches.
- Every CLI output log and `--output` report/evidence bundle.
- A `summary.json` identifying the CLI binary hash and per-case results after
  all expected outcomes have been verified.

The standalone smoke on the checked native x86-64 Linux host reports a
40-byte `GLFWgamepadstate` (15 button bytes and 24 axis bytes) and a 24-byte
`GLFWvidmode`. These observed values are evidence, not hardcoded layout
expectations in the selector manifest.

A passing result covers only the selected declarations, configuration,
toolchains, local library, and tested values. It does not certify every GLFW
function, every platform, or arbitrary prebuilt libraries. Header measurements
alone cannot establish that a separately supplied binary was built from those
headers; this example records and links the archive built from its pinned
source. Its three calls provide additional, limited runtime evidence.

The by-value shim demonstrates mixed-language aggregate transfer, not that an
upstream GLFW function uses that calling pattern. The injected regressions
demonstrate detection, not genuine upstream defects. No window/context creation,
display backend, threading scenario, or exhaustive callback input set is tested.
