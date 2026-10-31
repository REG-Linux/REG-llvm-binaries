#!/bin/sh

# Build the prebuilt LLVM tarball uploaded to
# github.com/REG-Linux/REG-llvm-binaries/releases/$(LLVM_VERSION).
#
# One bundle per CPU carries host/ and target/ for llvm, clang and libclc
# together; llvm.mk owns unpacking it and clang.mk/libclc.mk just depend on it.
#
# Usage:   ./scripts/linux/prebuild/prebuild-llvm.sh [cpu...]
# Example: ./scripts/linux/prebuild/prebuild-llvm.sh cortex_a76_a55 x86_64_v3
#          With no argument every CPU in the table below is built.
#
# Output:  prebuilt/reglinux-llvm-{host,target}-${LLVM_VERSION}-${cpu}.tar.xz
#          prebuilt/reglinux-spirv-tools-{host,target}-${SPIRV_TOOLS_VERSION}-${cpu}.tar.xz
#          prebuilt/reglinux-spirv-llvm-translator-{host,target}-<llvmtag>-<spirvhdrs>-${cpu}.tar.xz
#
# Three separate releases on REG-llvm-binaries, each tagged for what it is
# actually keyed on, so a bump of one leaves the others untouched:
#   llvm-${LLVM_VERSION}
#   spirv-tools-${SPIRV_TOOLS_VERSION}
#   spirv-llvm-translator-${LLVM_VERSION}-${SPIRV_HEADERS_VERSION}
#
# Run from the project root.

set -e

# Grab the LLVM version from the source tree
LLVM_MAJOR="$(awk -F'= ' '/^LLVM_PROJECT_VERSION_MAJOR /{print $2; exit}' \
    custom/package/llvm-project/llvm-project.mk)"
LLVM_VERSION_TPL="$(awk -F'= ' '/^LLVM_PROJECT_VERSION /{print $2; exit}' \
    custom/package/llvm-project/llvm-project.mk)"
LLVM_VERSION="$(echo "$LLVM_VERSION_TPL" | sed "s|\$(LLVM_PROJECT_VERSION_MAJOR)|$LLVM_MAJOR|g")"

SPIRV_TOOLS_VERSION="$(awk -F'= ' '/^SPIRV_TOOLS_VERSION /{print $2; exit}' \
	custom/package/spirv-tools/spirv-tools.mk)"
SPIRV_HEADERS_VERSION="$(awk -F'= ' '/^SPIRV_HEADERS_VERSION /{print $2; exit}' \
	custom/package/spirv-headers/spirv-headers.mk)"

if [ -z "$LLVM_VERSION" ]; then
	echo "Could not determine LLVM version, aborting"
	exit 1
fi

echo "Building LLVM/clang/libclc ${LLVM_VERSION} prebuilts"

# Create prebuilt output directory
mkdir -p prebuilt

# Enable BUILD_FROM_SOURCE in the shared defconfig fragment - for all three
# families, not just LLVM - otherwise each per-arch build just downloads the
# very tarball we are trying to produce, and 404s because it does not exist yet.
sed -i 's|^#\?BR2_PACKAGE_LLVM_BUILD_FROM_SOURCE=y|BR2_PACKAGE_LLVM_BUILD_FROM_SOURCE=y|' \
	configs/reglinux-board.common
sed -i 's|^#\?BR2_PACKAGE_SPIRV_TOOLS_BUILD_FROM_SOURCE=y|BR2_PACKAGE_SPIRV_TOOLS_BUILD_FROM_SOURCE=y|' \
	configs/reglinux-board.common
sed -i 's|^#\?BR2_PACKAGE_SPIRV_LLVM_TRANSLATOR_BUILD_FROM_SOURCE=y|BR2_PACKAGE_SPIRV_LLVM_TRANSLATOR_BUILD_FROM_SOURCE=y|' \
	configs/reglinux-board.common

PROJECT_DIR="$(pwd)"

# Rewrite the RUNPATHs of a host bundle's own ELFs to be $ORIGIN-relative.
#
# cmake bakes an absolute HOST_DIR/lib into everything it links, and HOST_DIR is
# *this* board's tree - /h3/per-package/host-spirv-tools/host/lib when the
# cortex_a7 bundle is harvested on h3. Every other board on that CPU then
# unpacks a bundle naming a directory it does not have: buildroot's
# check-host-rpath rejects the binaries at the end of install-host, and because
# DT_RUNPATH does not carry over to a library's own NEEDED entries, the
# libraries cannot find each other at runtime either. That is what broke cha
# (cortex_a7, like h3) on 2026-08-30.
#
# llvm.mk, spirv-tools.mk and spirv-llvm-translator.mk do the same rewrite when
# they unpack, because bundles published before this existed cannot be fixed
# from here. Both ends on purpose: this makes new bundles portable, the consumer
# hooks keep the old ones working, and they cost nothing once every published
# bundle is relocatable.
#
# $1 = file list, paths relative to the output dir (per-package prefix included)
relocate_host_rpaths() {
	listname="$1"

	# Prefer the patchelf buildroot just built for this target. The tars run
	# outside the build container, and neither a GitHub runner nor a
	# developer's machine is guaranteed to have one installed.
	patchelf=""
	for c in per-package/host-patchelf/host/bin/patchelf host/bin/patchelf; do
		if [ -x "${c}" ]; then
			patchelf="${c}"
			break
		fi
	done
	[ -n "${patchelf}" ] || patchelf="$(command -v patchelf || :)"
	if [ -z "${patchelf}" ]; then
		echo "ERROR: no patchelf, so this bundle's RUNPATHs would keep naming"
		echo "       $(pwd) - a path only this board has. Build it first:"
		echo "       PKG=host-patchelf make <target>-pkg"
		exit 1
	fi

	# host/bin/* and host/lib/*.so* only. Staging paths live deeper, under
	# host/<tuple>/sysroot/usr/, and the [^/]+$ anchor keeps them out: those
	# are target binaries whose RPATHs are the device's business, not ours.
	grep -E '(^|/)host/(bin/[^/]+|lib/[^/]+\.so[^/]*)$' "${listname}" \
		>"${listname}.elf" || :

	n=0
	while read -r f; do
		[ -f "${f}" ] || continue
		# patchelf materialises a symlink into a full copy; the target it
		# points at is in the list too and carries the RPATH anyway.
		[ -L "${f}" ] && continue
		cur="$("${patchelf}" --print-rpath "${f}" 2>/dev/null)" || continue
		# Leave alone anything that never had an RPATH - no need to invent one.
		[ -n "${cur}" ] || continue
		case "${f}" in
			*/bin/*) rp='$ORIGIN/../lib' ;;
			*)       rp='$ORIGIN' ;;
		esac
		# Rewrite unless it is already exactly right. Testing for "mentions
		# $ORIGIN somewhere" is not enough: cmake emits
		# "<HOST_DIR>/lib:$ORIGIN/../lib" for a fifth of these files, which
		# check-host-rpath accepts - it matches on any one entry - while still
		# naming the board that built the bundle. Nothing here has ever had a
		# relative entry worth preserving; every RPATH in the published bundles
		# is either purely absolute or that one absolute:$ORIGIN pair.
		[ "${cur}" = "${rp}" ] && continue
		"${patchelf}" --set-rpath "${rp}" "${f}" || continue
		n=$((n + 1))
	done <"${listname}.elf"
	rm -f "${listname}.elf"

	echo "    relocated ${n} RUNPATHs"
}

# Write one tarball from buildroot's own per-package manifests.
#
# Buildroot records exactly what each package installed in
#   build/<pkg>-<ver>/.files-list-host.txt     (paths relative to HOST_DIR)
#   build/<pkg>-<ver>/.files-list-staging.txt  (paths relative to STAGING_DIR)
#   build/<pkg>-<ver>/.files-list.txt          (paths relative to TARGET_DIR)
# as "<pkgname>,./path" lines, the same manifests prebuild-mames.sh uses.
#
# Package strictly from those. A per-package directory is NOT the set of files
# its package installed: buildroot pre-populates it by rsyncing in every
# dependency, so copying it wholesale - or sweeping it with a name heuristic
# like `find -ipath '*llvm*'` - ships other packages' binaries. Those carry
# RUNPATHs pointing into this build tree, and buildroot's check-host-rpath then
# rejects them in whoever consumes the tarball.
#
# $1 = tarball, $2 = scratch list file, $3 = half (host|target), $4.. = build dirs
#
# The two halves come from different manifests: .files-list-host.txt and
# .files-list-staging.txt describe HOST_DIR (staging lives under it as
# <tuple>/sysroot), .files-list.txt describes TARGET_DIR.
make_tarball() {
	tarball="$1"; shift
	listname="$1"; shift
	half="$1"; shift

	: >"${listname}"

	for d in "$@"; do
		[ -d "${d}" ] || continue

		# The manifests' first field is the buildroot package name, which is
		# also its per-package directory name.
		pkg=""
		for m in .files-list-host.txt .files-list-staging.txt .files-list.txt; do
			if [ -f "${d}/${m}" ]; then
				pkg="$(cut -d ',' -f 1 "${d}/${m}" | head -1)"
				if [ -n "${pkg}" ]; then
					break
				fi
			fi
		done
		[ -n "${pkg}" ] || continue

		if [ -d per-package ]; then
			hostpfx="per-package/${pkg}/host"
			tgtpfx="per-package/${pkg}/target"
		else
			hostpfx="host"
			tgtpfx="target"
		fi

		# STAGING_DIR lives under HOST_DIR as <tuple>/sysroot
		sysroot="$(cd "${hostpfx}" 2>/dev/null && ls -d ./*/sysroot 2>/dev/null | sed 's|^\./||' | head -1 || true)"

		if [ "${half}" = host ] && [ -f "${d}/.files-list-host.txt" ]; then
			cut -d ',' -f 2- "${d}/.files-list-host.txt" \
				| sed -e "s+^\./+${hostpfx}/+" >>"${listname}"
		fi
		if [ "${half}" = host ] && [ -f "${d}/.files-list-staging.txt" ] && [ -n "${sysroot}" ]; then
			cut -d ',' -f 2- "${d}/.files-list-staging.txt" \
				| sed -e "s+^\./+${hostpfx}/${sysroot}/+" >>"${listname}"
		fi
		if [ "${half}" = target ] && [ -f "${d}/.files-list.txt" ]; then
			cut -d ',' -f 2- "${d}/.files-list.txt" \
				| sed -e "s+^\./+${tgtpfx}/+" >>"${listname}"
		fi
	done

	# Drop Python bytecode caches. None of the packages harvested here is a
	# Python package - they land in the manifests only because buildroot derives
	# them from a find snapshot around install, and running python during a
	# build rewrites its own __pycache__ inside HOST_DIR. Shipping them is dead
	# weight: PEP 3147 reaches a __pycache__ entry only *through* its source, and
	# the sources are not in these bundles, so the files are unreachable.
	#
	# This is a subtraction of a known artifact, not a name-based selection -
	# the list is still built purely from the manifests. If a genuine Python
	# package is ever added to the harvest, revisit: its own bytecode ships with
	# its sources and would be legitimate.
	grep -v '/__pycache__/' "${listname}" >"${listname}.nopyc" || :
	mv "${listname}.nopyc" "${listname}"

	if [ ! -s "${listname}" ]; then
		echo "    nothing to package for $(basename "${tarball}"), skipping"
		return 0
	fi

	# LC_ALL=C: under a UTF-8 locale sort ignores punctuation at the primary
	# collation level, so "LLVM-Config.cmake" and "LLVMConfig.cmake" compare
	# equal and -u silently drops one of them. That cost the llvm tarball its
	# LLVMConfig.cmake, and any dependent doing find_package(LLVM) then failed
	# with "Could not find a package configuration file provided by LLVM".
	LC_ALL=C sort -u -o "${listname}" "${listname}"

	# Then dedupe again on the name the file will have *inside* the archive.
	# With per-package directories every package gets its own HOST_DIR, so a file
	# that several of them touch is listed once per package under a different
	# per-package/<pkg>/ prefix - distinct lines, which sort -u keeps, but the
	# --transform below collapses them to one member name. That put four copies
	# of host/lib/python3.12/__pycache__/_sysconfigdata__*.pyc in the llvm bundle,
	# same path, different bytes (python regenerated the cache in each tree), with
	# whichever came last winning on extraction. Keep the first and drop the rest.
	awk '{ k = $0; sub(/^per-package\/[^/]*\//, "", k); if (!seen[k]++) print }' \
		"${listname}" >"${listname}.uniq"
	mv "${listname}.uniq" "${listname}"

	# A host bundle made entirely of staging paths means no .files-list-host.txt
	# contributed anything - i.e. the package's host variant was never built, so
	# nothing was installed into HOST_DIR. Staging lives *under* HOST_DIR as
	# <tuple>/sysroot, so such a bundle still looks superficially right: correct
	# top-level prefix, plausible file count. That is exactly how a spirv-tools
	# host bundle of 45 staging paths and zero HOST_DIR files got published, and
	# it only surfaced ~70k log lines into a consumer build when host-glslang
	# could not find SPIRV-Tools-opt's cmake config.
	# grep -cv, not -qv: ugrep's -q reports whether the *pattern* matched and
	# ignores -v, so `! grep -qv` rejects everything under it. -c honours -v in
	# both greps. It exits 1 on a zero count, hence the || :.
	nonstaging=$(grep -cv '/sysroot/' "${listname}" || :)
	if [ "${half}" = host ] && [ "${nonstaging:-0}" -eq 0 ]; then
		echo "ERROR: every path in ${listname} is under <tuple>/sysroot, so this"
		echo "       host bundle carries staging only and nothing for HOST_DIR."
		echo "       The host variant of the package was probably never built -"
		echo "       check that the build step names it (e.g. PKG=host-spirv-tools)."
		exit 1
	fi

	# Guard against harvesting a tree that consumed the prebuilt LLVM instead
	# of building it: there the manifests record everything the tarball
	# extraction dropped in, rootfs skeleton included, and we would republish
	# the pollution we are trying to remove. A from-source LLVM installs
	# nothing under target/{dev,etc,sbin,var}.
	if grep -qE '(^|/)target/(dev|etc|sbin|var)/|THIS_IS_NOT_YOUR_ROOT_FILESYSTEM' "${listname}"; then
		echo "ERROR: ${listname} contains rootfs skeleton paths, so this tree"
		echo "       was built against the prebuilt LLVM rather than from source."
		echo "       Check BR2_PACKAGE_LLVM_BUILD_FROM_SOURCE=y in configs/reglinux-board.common."
		exit 1
	fi

	echo "    $(wc -l <"${listname}") files -> $(basename "${tarball}")"

	if [ "${half}" = host ]; then
		relocate_host_rpaths "${listname}"
	fi

	# With per-package directories the members are prefixed by
	# per-package/<pkg>/; strip that so the archive is always host/... plus
	# target/..., which is the layout llvm.mk's extract commands expect.
	#
	# flags=rh keeps the rewrite to member names and hard-link targets;
	# symlink targets (flag s, on by default) must stay as the package wrote
	# them.
	XZ_OPT=-9 tar -cJf "${tarball}" \
		--transform='flags=rh;s|^per-package/[^/]*/||' \
		--verbatim-files-from -T "${listname}"
}

# One build per CPU, not per board: llvm.mk picks the prebuilt by CPU
# (REGLINUX_LLVM_CPU), so the target named here is just a representative board
# for that CPU and every other board sharing it takes the same tarball. Keep
# this list in step with the matrix in
# REG-llvm-binaries/.github/workflows/build-llvm.yml.
#
# cortex_x3 and riscv_rvv are absent on purpose: unlike MAME, llvm.mk folds
# every ARMv9-A core into cortex_a76_a55 and every RISC-V into riscv64.
while read -r cpu target
do
	[ -n "${cpu}" ] || continue

	# Optional CPU filter from the command line
	if [ -n "$1" ]; then
		wanted=n
		for want in "$@"; do
			if [ "${want}" = "${cpu}" ]; then
				wanted=y
			fi
		done
		if [ "${wanted}" != y ]; then
			continue
		fi
	fi

	echo "==> Building LLVM toolchain for ${cpu} (via ${target})"

	# Clean
	make "${target}-clean"
	# Build
	# libclc depends on clang, which depends on llvm, so this one invocation builds all three.
	PKG=libclc                make "${target}-pkg" DEBUG_BUILD=n CCACHE_DISABLE=1
	# host-lld too: nothing depends on it either, so it only builds when named.
	# Its lld goes in the llvm host bundle - LTO consumers need a linker that
	# reads bitcode, and binutils ld is not it.
	PKG=host-lld              make "${target}-pkg" DEBUG_BUILD=n CCACHE_DISABLE=1
	# host-spirv-tools explicitly: unlike the others, nothing in the target
	# package's dependency chain pulls it in (SPIRV_TOOLS_DEPENDENCIES names only
	# spirv-headers), so PKG=spirv-tools alone leaves build/host-spirv-tools-*
	# absent - and the host bundle then gets harvested from the target package's
	# .files-list-staging.txt only, 45 staging paths and not one real HOST_DIR
	# file. host-glslang then fails to configure with "SPIR-V tools not found".
	# libclc and spirv-llvm-translator do pull their host variants, so they need
	# no equivalent line.
	PKG=spirv-tools           make "${target}-pkg" DEBUG_BUILD=n CCACHE_DISABLE=1
	PKG=host-spirv-tools      make "${target}-pkg" DEBUG_BUILD=n CCACHE_DISABLE=1
	PKG=spirv-llvm-translator make "${target}-pkg" DEBUG_BUILD=n CCACHE_DISABLE=1
	# The harvest's own tool, in no bundle: relocate_host_rpaths needs it and
	# runs outside the container, where there may be no system patchelf.
	PKG=host-patchelf         make "${target}-pkg" DEBUG_BUILD=n CCACHE_DISABLE=1
	# Package. Subshell: the tars run from the output directory, but the next
	# iteration has to start back at the top of the tree.
	(
		cd "output/${target}" || exit 1
		# Two bundles, matching the two package variants in llvm.mk:
		# the host one is what every board needs for mesa-clc, the target
		# one only boards that ship libLLVM or cross-build against it.
		# host-llvm-* also covers host-llvm-cmake and host-llvm-libunwind;
		# host-lld needs its own entry, the glob does not reach it. Both
		# deliberately exclude host-spirv-llvm-translator, which owns
		# llvm-spirv and is still built from source per board.
		make_tarball "${PROJECT_DIR}/prebuilt/reglinux-llvm-host-${LLVM_VERSION}-${cpu}.tar.xz" \
			llvm-host-filelist.txt host \
			build/llvm-* build/host-llvm-* \
			build/clang-* build/host-clang-* \
			build/libclc-* build/host-libclc-* \
			build/host-lld-*
		make_tarball "${PROJECT_DIR}/prebuilt/reglinux-llvm-target-${LLVM_VERSION}-${cpu}.tar.xz" \
			llvm-target-filelist.txt target \
			build/llvm-* build/host-llvm-* \
			build/clang-* build/host-clang-* \
			build/libclc-* build/host-libclc-* \
			build/host-lld-*

		# spirv-tools: keyed on its own Vulkan-SDK version, no LLVM in the name
		make_tarball "${PROJECT_DIR}/prebuilt/reglinux-spirv-tools-host-${SPIRV_TOOLS_VERSION}-${cpu}.tar.xz" \
			spirv-tools-host-filelist.txt host \
			build/spirv-tools-* build/host-spirv-tools-*
		make_tarball "${PROJECT_DIR}/prebuilt/reglinux-spirv-tools-target-${SPIRV_TOOLS_VERSION}-${cpu}.tar.xz" \
			spirv-tools-target-filelist.txt target \
			build/spirv-tools-* build/host-spirv-tools-*

		# translator: two-version key - it is compiled against both the LLVM
		# major and spirv-headers, and those move independently
		make_tarball "${PROJECT_DIR}/prebuilt/reglinux-spirv-llvm-translator-host-${LLVM_VERSION}-${SPIRV_HEADERS_VERSION}-${cpu}.tar.xz" \
			spirv-translator-host-filelist.txt host \
			build/spirv-llvm-translator-* build/host-spirv-llvm-translator-*
		make_tarball "${PROJECT_DIR}/prebuilt/reglinux-spirv-llvm-translator-target-${LLVM_VERSION}-${SPIRV_HEADERS_VERSION}-${cpu}.tar.xz" \
			spirv-translator-target-filelist.txt target \
			build/spirv-llvm-translator-* build/host-spirv-llvm-translator-*
	) || exit 1
	# Clean again
	make "${target}-clean"
done <<EOF
arm1176jzf_s bcm2835
cortex_a7 h3
cortex_a9 s812
cortex_a15_a7 odroidxu4
cortex_a17 rk3288
cortex_a35 rk3326
cortex_a53 h616
cortex_a55 rk3568
cortex_a57 l4t
cortex_a72 bcm2711
cortex_a72_a53 rk3399
cortex_a73_a53 s922x
cortex_a75_a55 sdm845
cortex_a76 bcm2712
cortex_a76_a55 sm8250
riscv64 jh7110
saphira asahi
x86_64 x86_64
x86_64_v3 x86_64_v3
EOF

# Disable the flag to build LLVM from source
sed -i 's|^BR2_PACKAGE_LLVM_BUILD_FROM_SOURCE=y|#BR2_PACKAGE_LLVM_BUILD_FROM_SOURCE=y|' \
	configs/reglinux-board.common
sed -i 's|^BR2_PACKAGE_SPIRV_TOOLS_BUILD_FROM_SOURCE=y|#BR2_PACKAGE_SPIRV_TOOLS_BUILD_FROM_SOURCE=y|' \
	configs/reglinux-board.common
sed -i 's|^BR2_PACKAGE_SPIRV_LLVM_TRANSLATOR_BUILD_FROM_SOURCE=y|#BR2_PACKAGE_SPIRV_LLVM_TRANSLATOR_BUILD_FROM_SOURCE=y|' \
	configs/reglinux-board.common

echo
echo "Tarballs in ./prebuilt/. Upload each family to its own release:"
echo "  reglinux-llvm-*                  -> tag llvm-${LLVM_VERSION}"
echo "  reglinux-spirv-tools-*           -> tag spirv-tools-${SPIRV_TOOLS_VERSION}"
echo "  reglinux-spirv-llvm-translator-* -> tag spirv-llvm-translator-${LLVM_VERSION}-${SPIRV_HEADERS_VERSION}"
echo "  https://github.com/REG-Linux/REG-llvm-binaries/releases"
