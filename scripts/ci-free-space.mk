# CI disk-space hooks for the REG-WIP buildroot tree. The workflows copy this
# to output/<target>/local.mk before building:
#
#   cp scripts/ci-free-space.mk output/<target>/local.mk
#
# It lives here rather than in REG-WIP because it is CI-only policy: nothing in
# a normal `make <target>-build` should be deleting downloads behind your back.
#
# Buildroot includes $(CONFIG_DIR)/local.mk -- its BR2_PACKAGE_OVERRIDE_FILE,
# which defaults to "output/<target>/local.mk" -- before every package .mk, so
# it is a supported place to append to GLOBAL_INSTRUMENTATION_HOOKS. Each hook
# in that list is called by pkg-generic.mk at every build step with
# ($1=start|end, $2=step name, $3=package name), and its expansion is pasted
# into that step's recipe, so the body needs a leading tab like any recipe.
#
# Do NOT get the same effect by sed'ing buildroot/package/pkg-generic.mk: that
# file is owned by custom/package/pkg-generic.mk.patch, and every
# `make <target>-*` goal depends on the `merge` target, so the next make runs
# mergeToBR.sh over the sed'ed file and aborts with "target file does not have
# expected MD5 checksum".

# A package and its host/target twin share one download directory: both
# host-qt6base and qt6base pull $(DL_DIR)/qt6base. So whoever installs first
# must leave the tarball alone, or the second one downloads it all over again
# (~1GB across the qt6 sub-packages). These two give the twin's package name
# (to test membership of $(PACKAGES), buildroot's list of enabled packages)
# and its uppercase variable prefix.
reg_ci_twin_name = $(if $(filter host-%,$(1)),$(patsubst host-%,%,$(1)),host-$(1))
reg_ci_twin_pfx  = $(if $(filter HOST_%,$(1)),$(patsubst HOST_%,%,$(1)),HOST_$(1))

# A few download directories are shared by more than a host/target twin, so the
# twin test above cannot tell when the last consumer is done: $(DL_DIR)/gcc
# feeds host-gcc-initial, host-gcc-final and gcc-final, and $(DL_DIR)/linux
# feeds both linux-headers and linux. Never clean those - a kernel or gcc
# tarball is small next to what qt6 costs, and re-downloading it is the exact
# waste this list exists to prevent. Matched against <pkg>_DL_SUBDIR.
REG_CI_DL_KEEP ?= gcc linux

# Drop a package's download directory once the package is installed.
# install-target and install-host are each package's last install step (a
# target package never runs install-host, a host package never runs
# install-target), so this fires exactly once per package.
#
#   * no twin in this build  -> nothing else wants the tarball, drop it now
#   * twin in this build     -> drop it only once the twin has reached
#                              .stamp_installed, its final stamp. Whichever of
#                              the two finishes last does the delete, so this
#                              holds whatever order they are built in. If the
#                              twin is enabled but never actually built (it is
#                              outside the goal's dependency closure) the
#                              tarball simply stays -- wasted disk, never a
#                              wasted download.
#
# The filter-out guard makes sure a package with an empty _DL_SUBDIR can never
# turn this into "rm -rf $(DL_DIR)".
define reg_ci_free_dl
	$(if $(filter end,$(1)),$(if $(filter install-target install-host,$(2)),\
		$(if $(filter-out $(DL_DIR) $(DL_DIR)/,$($(PKG)_DL_DIR)),\
		$(if $(filter $($(PKG)_DL_SUBDIR),$(REG_CI_DL_KEEP)),,\
			$(if $(filter $(call reg_ci_twin_name,$(3)),$(PACKAGES)),\
				test -e $($(call reg_ci_twin_pfx,$(PKG))_DIR)/.stamp_installed && rm -rf $($(PKG)_DL_DIR) || :,\
				rm -rf $($(PKG)_DL_DIR))))))
endef
GLOBAL_INSTRUMENTATION_HOOKS += reg_ci_free_dl
