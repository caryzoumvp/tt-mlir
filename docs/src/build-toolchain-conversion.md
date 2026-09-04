# Local LLVM/Conda Build Conversion

## Summary

The tt-mlir build was converted from the repository-managed dependency setup to
the workspace-managed toolchain:

- LLVM source: `/workspaces/llvm-project`
- LLVM revision: `4efe170d858eb54432f520abb4e7f0086236748b`
- tt-metal source: `/workspaces/tensix/tt-metal`
- C/C++ compiler: `clang-20` and `clang++-20`
- Python: Conda environment `tt-isaac-gr00t`
- LLVM install: `/workspaces/llvm-project/install-ttmlir-clang20-pinned`
- tt-mlir build: `build_x86v2_clang20`

The LLVM revision is materialized as a detached local Git worktree. No LLVM or
tt-metal repository clone is performed by `build_mlir.sh`.

## Build behavior

`build_mlir.sh` now validates the source checkouts and Python environment,
selects pybind11 2.10.x, and adds the existing FlatBuffers compiler to `PATH`.
LLVM/MLIR/LLD is built and installed only when explicitly requested:

```bash
BUILD_LLVM=ON JOBS=4 bash build_mlir.sh
```

After the one-time toolchain build, ordinary tt-mlir changes use:

```bash
JOBS=4 bash build_mlir.sh
```

The script verifies that the installed MLIR export contains the EmitC Python
target before starting a normal build.

## Repository modifications

### `build_mlir.sh`

- Removed the `env` ExternalProject bootstrap that cloned LLVM and tt-metal.
- Added local LLVM revision/worktree and install paths.
- Added optional (`BUILD_LLVM=ON`) LLVM/MLIR/LLD configure, build, and install.
- Uses Conda activation from `~/.conda_env.rc` and `tt-isaac-gr00t`.
- Uses Clang 20 and the Conda Python executable.
- Enforces LLVM's pybind11 requirement (`>=2.9.0, <=2.10.3`).
- Explicitly selects `/opt/ttmlir-toolchain/bin/flatc`.
- Passes the local MLIR, LLVM, LLD, and tt-metal paths to tt-mlir.

### `CMakeLists.txt`

The dependency include directory is marked `SYSTEM`, preventing old MLIR
headers under `/opt/ttmlir-toolchain/include` from overriding the selected
workspace LLVM headers while retaining FlatBuffers headers.

### `lib/Dialect/TTNN/Transforms/CMakeLists.txt`

The pybind11 translation unit retains RTTI and exceptions and suppresses
Clang 20's `-Wdeprecated-literal-operator` diagnostics emitted by pybind11
2.10.3 headers. The suppression is local to
`TTNNResolveTTLangKernelsPython.cpp`.

### `tools/ttmlir-opt/CMakeLists.txt`

The Linux linker is instructed to retain the weak VTT symbol for
`BufferDeallocationPipelineOptions`, preventing `--gc-sections` from dropping
the symbol needed when querying pipeline options.

## External environment change

The active Conda environment had pybind11 3.0.2, which is incompatible with
this LLVM snapshot's Python bindings. It was changed to pybind11 2.10.3 in
`tt-isaac-gr00t`; no Python package was installed into
`/opt/ttmlir-toolchain`.

## Validation and remaining status

Configuration succeeds with LLVM/MLIR/LLD, EmitC Python bindings, Conda
Python/NumPy, pybind11 2.10.3, Clang 20, and local tt-metal. FlatBuffer code
generation succeeds after explicitly selecting `flatc`. The incremental
tt-mlir build passed the original pybind11 literal-operator failure and
advanced through hundreds of Ninja targets. The full build should be allowed
to complete with `cmake --build build_x86v2_clang20 -j4`; CMake RPATH messages
about Conda's `libz`/`libzstd` are warnings, not build errors.
