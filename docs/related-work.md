# ImportC and importc_compare

ImportC and dabiprobe address different parts of C interoperation. Neither needs
to replace the other.

**[ImportC](https://dlang.org/spec/importc.html)** compiles and imports C declarations
through the D compiler. It can remove the need to translate those declarations
by hand. dabiprobe instead checks selected declarations already used by a binding,
with measurements compiled by the project's separate C toolchain.

**[importc_compare](https://github.com/dlang/dmd/blob/cb7bb99ef8531461ebb0757cc02a829df15ca029/druntime/test/importc_compare/src/importc_compare.d)**
already uses reflection to compare substantial declaration information against
ImportC's view of C headers. At the linked revision it collects named types,
members, sizes, offsets, bitfield metadata, and numerical constants. Function
signatures are marked as future work; the comparison does not run library calls
or callbacks. These are observations about that revision, not claims about every
version or other tools built around ImportC.

dabiprobe's practical contribution is the combination of:

- Independent C-compiler measurements under named project build configurations.
- Reflected D field and function selection without a second handwritten binding.
- Explicit, separately reported cross-language assertions.
- Honest coverage states and retained sources, commands, and diagnostics for
  reproduction outside the verifier.

The [BindBC-GLFW case study](glfw-case-study.md) demonstrates that workflow and
its remaining boundaries. Its intentionally injected regressions are test cases,
not discovered upstream defects. It does not depend on a claim that ImportC is
incorrect or that declaration comparison is a new idea.
