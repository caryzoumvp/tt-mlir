#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

# Use the workspace-managed LLVM and tt-metal checkouts.  Do not invoke
# env/build here: it declares ExternalProjects and would clone LLVM/tt-metal.
LLVM_PROJECT_DIR="${LLVM_PROJECT_DIR:-/workspaces/llvm-project}"
LLVM_PROJECT_COMMIT="${LLVM_PROJECT_COMMIT:-4efe170d858eb54432f520abb4e7f0086236748b}"
LLVM_SOURCE_DIR="${LLVM_SOURCE_DIR:-${LLVM_PROJECT_DIR}-ttmlir-${LLVM_PROJECT_COMMIT:0:12}}"
LLVM_BUILD_DIR="${LLVM_BUILD_DIR:-${LLVM_PROJECT_DIR}/build-ttmlir-clang20-pinned}"
LLVM_INSTALL_DIR="${LLVM_INSTALL_DIR:-${LLVM_PROJECT_DIR}/install-ttmlir-clang20-pinned}"
TTMETAL_SOURCE_DIR="${TTMETAL_SOURCE_DIR:-/workspaces/tensix/tt-metal}"
TTMLIR_BUILD_DIR="${TTMLIR_BUILD_DIR:-build_x86v2_clang20}"
CONDA_ENV_NAME="${CONDA_ENV_NAME:-tt-isaac-gr00t}"
BUILD_LLVM="${BUILD_LLVM:-OFF}"
CC="${CC:-clang-20}"
CXX="${CXX:-clang++-20}"

for required_dir in "$LLVM_PROJECT_DIR" "$TTMETAL_SOURCE_DIR"; do
  if [[ ! -d "$required_dir" ]]; then
    echo "ERROR: required source directory does not exist: $required_dir" >&2
    exit 1
  fi
done

# Reuse the locally available pinned revision through a worktree. This avoids
# changing the user's main LLVM checkout and never downloads or clones it.
if [[ ! -d "$LLVM_SOURCE_DIR/llvm" ]]; then
  git -C "$LLVM_PROJECT_DIR" worktree add --detach "$LLVM_SOURCE_DIR" "$LLVM_PROJECT_COMMIT"
fi
if [[ "$(git -C "$LLVM_SOURCE_DIR" rev-parse HEAD)" != "$LLVM_PROJECT_COMMIT" ]]; then
  echo "ERROR: $LLVM_SOURCE_DIR is not at LLVM commit $LLVM_PROJECT_COMMIT" >&2
  exit 1
fi

# Use the workspace Conda environment. Do not activate or install into the
# /opt/ttmlir-toolchain virtual environment.
source ~/.conda_env.rc
conda activate "$CONDA_ENV_NAME"
export TTMLIR_ENV_ACTIVATED=1
export TTMLIR_TOOLCHAIN_DIR="${TTMLIR_TOOLCHAIN_DIR:-/opt/ttmlir-toolchain}"
export TTMLIR_VENV_DIR="$CONDA_PREFIX"
export PATH="$TTMLIR_TOOLCHAIN_DIR/bin:$CONDA_PREFIX/bin:$PATH"

# This LLVM snapshot requires the pybind11 range recorded in
# mlir/python/requirements.txt. Pybind11 3 rejects an MLIR binding pattern
# used by IRCore.cpp, so fail before an expensive build if the Conda env drifts.
python -c '
import pybind11
version = tuple(map(int, pybind11.__version__.split(".")[:3]))
if not (version >= (2, 9, 0) and version <= (2, 10, 3)):
    raise SystemExit(
        f"Unsupported pybind11 {pybind11.__version__}; LLVM requires >=2.9.0, <=2.10.3"
    )
'

# tt-mlir links lldELF to support in-process linking. Build LLVM only when
# explicitly requested (initial setup or after changing LLVM); normal tt-mlir
# source edits should reuse the existing local LLVM build.
if [[ "$BUILD_LLVM" == "ON" ]]; then
  cmake -G Ninja -S "$LLVM_SOURCE_DIR/llvm" -B "$LLVM_BUILD_DIR" \
    -DCMAKE_BUILD_TYPE="${LLVM_BUILD_TYPE:-Release}" \
    -DCMAKE_INSTALL_PREFIX="$LLVM_INSTALL_DIR" \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_CXX_COMPILER="$CXX" \
    -DPython3_EXECUTABLE="$CONDA_PREFIX/bin/python" \
    -DLLVM_ENABLE_PROJECTS="mlir;lld" \
    -DLLVM_TARGETS_TO_BUILD=host \
    -DLLVM_ENABLE_ASSERTIONS=ON \
    -DMLIR_ENABLE_BINDINGS_PYTHON=ON
  cmake --build "$LLVM_BUILD_DIR" -j "${JOBS:-$(nproc)}"
  cmake --install "$LLVM_BUILD_DIR"
elif [[ ! -f "$LLVM_INSTALL_DIR/lib/cmake/mlir/MLIRConfig.cmake" || \
        ! -f "$LLVM_INSTALL_DIR/lib/cmake/lld/LLDConfig.cmake" || \
        ! -f "$LLVM_INSTALL_DIR/lib/cmake/mlir/MLIRTargets.cmake" ]] || \
      ! grep -q 'MLIRPythonSources.Dialects.emitc' \
        "$LLVM_INSTALL_DIR/lib/cmake/mlir/MLIRTargets.cmake"; then
  echo "ERROR: installed LLVM/MLIR/LLD is not ready at $LLVM_INSTALL_DIR." >&2
  echo "Run BUILD_LLVM=ON JOBS=4 bash build_mlir.sh once to build and install it." >&2
  exit 1
fi

if [[ ! -f "$TTMLIR_BUILD_DIR/build.ninja" || "${RECONFIGURE:-OFF}" == "ON" ]]; then
  # Configure tt-mlir for x86-64-v2. Reconfiguring resets the tt-metal
  # ExternalProject, so preserve the existing Ninja tree for delta builds.
  cmake -G Ninja -B "$TTMLIR_BUILD_DIR" \
    -DCMAKE_BUILD_TYPE="${BUILD_TYPE:-Release}" \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_CXX_COMPILER="$CXX" \
    -DMLIR_DIR="$LLVM_INSTALL_DIR/lib/cmake/mlir" \
    -DLLVM_DIR="$LLVM_INSTALL_DIR/lib/cmake/llvm" \
    -DLLD_DIR="$LLVM_INSTALL_DIR/lib/cmake/lld" \
    -DTTMLIR_TTMETAL_SOURCE_DIR="$TTMETAL_SOURCE_DIR" \
    -DFLATBUFFERS_COMPILER="$TTMLIR_TOOLCHAIN_DIR/bin/flatc" \
    -DTTMLIR_ENABLE_RUNTIME="${TTMLIR_ENABLE_RUNTIME:-ON}" \
    -DTTMLIR_ENABLE_STABLEHLO="${TTMLIR_ENABLE_STABLEHLO:-ON}" \
    -DTT_RUNTIME_ENABLE_TTNN="${TT_RUNTIME_ENABLE_TTNN:-ON}" \
    -DTT_RUNTIME_ENABLE_TTMETAL="${TT_RUNTIME_ENABLE_TTMETAL:-ON}" \
    -DTT_RUNTIME_ENABLE_DISTRIBUTED="${TT_RUNTIME_ENABLE_DISTRIBUTED:-ON}" \
    -DTTMLIR_ENABLE_TESTS="${TTMLIR_ENABLE_TESTS:-OFF}" \
    -DCMAKE_C_FLAGS="${CMAKE_C_FLAGS_EXTRA:--march=x86-64-v2}" \
    -DCMAKE_CXX_FLAGS="${CMAKE_CXX_FLAGS_EXTRA:--march=x86-64-v2}"
fi

cmake --build "$TTMLIR_BUILD_DIR" -j "${JOBS:-$(nproc)}"
if [[ ! -f "$TTMLIR_BUILD_DIR/build.ninja" ]]; then
  echo "ERROR: configure did not generate $TTMLIR_BUILD_DIR/build.ninja" >&2
  exit 1
fi

echo "Build complete: $ROOT_DIR/$TTMLIR_BUILD_DIR (TTMLIR_ENABLE_TESTS=${TTMLIR_ENABLE_TESTS:-OFF})"
