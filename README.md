# REG-llvm-binaries

Prebuilt LLVM, Clang, libclc, SPIRV-Tools and SPIRV-LLVM-Translator bundles, plus build caches,
used as build input for [REG-Linux](https://github.com/REG-Linux/REG-Linux). They exist only to
save CI time: everything here is built from upstream source with the recipe in [`recipe/`](recipe/).

## Releases

| Release tag | Contents | Corresponding source |
|---|---|---|
| `llvm-22.1.7` | LLVM, Clang, lld and libclc 22.1.7, per CPU target (`host` and `target` bundles) | [llvm-project-22.1.7.src.tar.xz](https://github.com/llvm/llvm-project/releases/download/llvmorg-22.1.7/llvm-project-22.1.7.src.tar.xz), SHA-256 `5cc4a3f12bba50b6bdfb4b61bdc852117a0ff2517807c3902fc13267fb93562e` |
| `spirv-tools-1.4.357.0` | SPIRV-Tools 1.4.357.0 | [vulkan-sdk-1.4.357.0](https://github.com/KhronosGroup/SPIRV-Tools/archive/refs/tags/vulkan-sdk-1.4.357.0.tar.gz), SHA-256 `d31e7109b6ef3559067e53e520870eafed7c9534d00db9728814b6df03fa4a5e` |
| `spirv-llvm-translator-22.1.7-1.4.357.0` | SPIRV-LLVM-Translator v22.1.5, built against LLVM 22.1.7 and SPIRV-Headers 1.4.357.0 | [v22.1.5](https://github.com/KhronosGroup/SPIRV-LLVM-Translator/archive/refs/tags/v22.1.5.tar.gz), SHA-256 `3c6dffb4b8d67f5c544370e0c869ec7d22c013d4bb798f24655ec903f26cc5d5` |
| `19.1.7` | Older LLVM/Clang/libclc 19.1.7 bundle, kept for older REG-Linux builds | [llvmorg-19.1.7](https://github.com/llvm/llvm-project/releases/tag/llvmorg-19.1.7) |
| `toolchain-<cpu>` | Build caches (Buildroot output trees incl. the cross toolchain) used by CI; not meant for direct use | see [Toolchain caches](#toolchain-caches) |

## What REG-Linux changes

The LLVM, SPIRV-Tools and SPIRV-LLVM-Translator sources are not modified beyond the small
Buildroot packaging fixes below. All of them are in [`recipe/`](recipe/):

- `llvm-project`: version bump to 22.1.7, one shared source tarball for all components,
  prebuilt-bundle selection per CPU.
- `clang`: `GCC_INSTALL_PREFIX` handling and LLVM cmake path fixes (Buildroot patches, carried unchanged).
- `compiler-rt`: `#include <cstdint>` fix (Buildroot patch).
- `spirv-llvm-translator`: honour `BR2_CCACHE`.

The build script is `recipe/scripts/linux/prebuild/prebuild-llvm.sh`. Patches are merged into
Buildroot by `recipe/scripts/buildroot/mergeToBR.sh`; the Buildroot tree is
[REG-Linux/REG-Linux](https://github.com/REG-Linux/REG-Linux) plus
[REG-Linux/buildroot](https://github.com/REG-Linux/buildroot).

## Licences

| Component | Licence | Text |
|---|---|---|
| LLVM, Clang, lld, compiler-rt | Apache-2.0 with LLVM exceptions | [`LICENSES/LLVM-Apache-2.0-with-LLVM-exception.txt`](LICENSES/LLVM-Apache-2.0-with-LLVM-exception.txt) |
| libclc | Apache-2.0 with LLVM exceptions or MIT | same file |
| SPIRV-Tools | Apache-2.0 | [`LICENSES/SPIRV-Tools-Apache-2.0.txt`](LICENSES/SPIRV-Tools-Apache-2.0.txt) |
| SPIRV-LLVM-Translator | LLVM Release License (NCSA) | [`LICENSES/SPIRV-LLVM-Translator-LLVM-Release-License.txt`](LICENSES/SPIRV-LLVM-Translator-LLVM-Release-License.txt) |

## Toolchain caches

The `toolchain-<cpu>` releases are Buildroot build outputs kept as a cache so CI does not rebuild
the cross toolchain every time. They contain GNU and other copyleft components, so their sources
are offered here:

- **GCC**: version depends on the board (GCC 13.x to 16.x); the version used by each board is set
  in its Buildroot configuration in [REG-Linux/REG-Linux](https://github.com/REG-Linux/REG-Linux).
  Source: https://ftp.gnu.org/gnu/gcc/ (GPL-3.0-or-later with the GCC Runtime Library Exception).
- **binutils** (Buildroot default 2.43.1; the exact version follows the board configuration): https://ftp.gnu.org/gnu/binutils/ (GPL-3.0-or-later).
- **glibc** 2.41 (git snapshot `2.41-123-gfb4db64a04ad`): commit `fb4db64a04ad6c96cd1fbb7e02eb59323b1f2ac2` of
  https://sourceware.org/git/glibc.git (LGPL-2.1-or-later).
- **Linux kernel headers, GMP, MPFR, MPC, and other Buildroot packages**: the exact versions and
  sources are those of the Buildroot tree named above. Buildroot can list them with `make legal-info`.

Licence texts: [`LICENSES/GPL-3.0-only.txt`](LICENSES/GPL-3.0-only.txt),
[`LICENSES/LGPL-2.1-or-later.txt`](LICENSES/LGPL-2.1-or-later.txt).

## Source requests

If you cannot get a source you need from the links above, open an issue on this repository or
use the contact on https://reglinux.org/legal/ and we will provide it.
