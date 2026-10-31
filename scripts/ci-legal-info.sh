#!/bin/bash
# Source and build recipe for a prebuilt bundle, from Buildroot's own
# per-package legal-info. Run from the REG-WIP checkout root, right after the
# packages were built, with the same PARALLEL_BUILD/DEBUG_BUILD/CCACHE_DISABLE
# environment the build used (they change the generated .config).
#
#   ci-legal-info.sh <target> <legal-name> <sources-name> <build-dir-glob>...
#
# The globs are the same ones the bundle's file list was harvested from
# (e.g. 'qt6*' 'host-qt6*'), relative to output/<target>/build. Writes:
#
#   <legal-name>.tar.xz   manifests, licence texts, the full .config, the
#                         package recipes (.mk/.hash/Config.in/patches) and
#                         BUILD-INFO.txt (commits, workflow, run)
#   <sources-name>.tar    the upstream source archives and every patch that
#                         was applied, exactly as built, plus licenses/ and
#                         host-licenses/ (REG-WIP's prebuilt packages take
#                         their licence texts from here for legal-info)
#
# REG-WIP is private, so the recipes are copied in rather than linked.
# CI_WORKFLOW_URL and CI_RUN_URL, if set, go into BUILD-INFO.txt.
set -euo pipefail

target="$1" legalname="$2" srcname="$3"
shift 3
root="$PWD"
out="output/${target}"
li="${out}/legal-info"

# Package names, read from the manifests rather than the directory names:
# versions can contain dashes. A dir with no manifest installed nothing.
pkgs=() dirs=()
for g in "$@"; do
	for d in "${out}"/build/${g}; do
		[ -d "$d" ] || continue
		p="$(awk -F, 'NR==1 { print $1; exit }' "$d"/.files-list*.txt 2>/dev/null || :)"
		[ -n "$p" ] || continue
		pkgs+=("$p") dirs+=("$d")
	done
done
if [ "${#pkgs[@]}" -eq 0 ]; then
	echo "ci-legal-info: no built packages match: $*" >&2
	exit 1
fi
echo "ci-legal-info: ${pkgs[*]}"

# ci-free-space.mk deleted the archives once each package was installed, and
# .stamp_downloaded stops Buildroot fetching them again. Drop the stamps,
# fetch, then put the old stamps back: a newer stamp would rebuild everything.
for d in "${dirs[@]}"; do
	[ -f "$d/.stamp_downloaded" ] && mv "$d/.stamp_downloaded" "$d/.stamp_downloaded.keep"
done
make "${target}-pkg" PKG="${pkgs[*]/%/-source}"
for d in "${dirs[@]}"; do
	[ -f "$d/.stamp_downloaded.keep" ] && mv -f "$d/.stamp_downloaded.keep" "$d/.stamp_downloaded"
done

# Two calls: legal-info-clean must finish before the manifests are started.
make "${target}-pkg" PKG="legal-info-clean legal-info-prepare"
make "${target}-pkg" PKG="${pkgs[*]/%/-legal-info}"

# Package recipes, after mergeToBR.sh, so custom/ changes are included. The
# parent's .mk goes too where packages share one (qt6.mk, llvm-project.mk).
recipe="${li}/recipe"
rm -rf "${recipe}"
for p in "${pkgs[@]}"; do
	base="${p#host-}"
	for d in $(find buildroot/package package -type d -name "${base}" 2>/dev/null); do
		[ -f "$d/${base}.mk" ] || continue
		mkdir -p "${recipe}/$d"
		cp -a "$d/." "${recipe}/$d/"
		parent="$(dirname "$d")"
		case "${parent}" in
		buildroot/package|package|package/*) ;;
		*) cp -a "${parent}"/*.mk "${recipe}/${parent}/" 2>/dev/null || : ;;
		esac
	done
done

br_sha="$(git rev-parse HEAD:buildroot 2>/dev/null || git -C buildroot rev-parse HEAD)"
cat > "${li}/BUILD-INFO.txt" <<EOF
Built for REG-Linux by ${CI_RUN_URL:-a local run}

Board configuration:  ${target} (full .config in buildroot.config)
Packages:             ${pkgs[*]}
Build command:        PARALLEL_BUILD=${PARALLEL_BUILD:-y} DEBUG_BUILD=${DEBUG_BUILD:-y} make ${target}-pkg PKG=<package>
Workflow:             ${CI_WORKFLOW_URL:-n/a}
REG-Linux tree:       REG-WIP $(git rev-parse HEAD 2>/dev/null || echo unknown)
Buildroot:            https://gitlab.com/buildroot.org/buildroot/-/tree/${br_sha}

Upstream source archives and the patches applied to them are in
${srcname}.tar, one directory per package. manifest.csv and
host-manifest.csv give each package's version, licence, source archive
and download site. recipe/ holds the Buildroot package files the build
used, with REG-Linux's changes already merged in.
EOF

# A host package and its target twin share one source archive; hard-link the
# copies so the tarball carries each archive once.
(
	cd "${li}"
	find sources host-sources -type f -print0 2>/dev/null | xargs -0r sha256sum | sort |
	awk '{ if ($1 == h) print f "\t" $2; else { h = $1; f = $2 } }' |
	while IFS="$(printf '\t')" read -r keep dup; do ln -f "${keep}" "${dup}"; done
	find sources host-sources -type f -print0 2>/dev/null | xargs -0r sha256sum | LC_ALL=C sort -k2 > SOURCES.sha256
)

tar -C "${li}" -cf "${root}/${srcname}.tar" \
	$(cd "${li}" && ls -d sources host-sources licenses host-licenses 2>/dev/null)
XZ_OPT=-9 tar -C "${li}" -cJf "${root}/${legalname}.tar.xz" \
	--exclude=./sources --exclude=./host-sources .
echo "ci-legal-info: wrote ${legalname}.tar.xz and ${srcname}.tar"
