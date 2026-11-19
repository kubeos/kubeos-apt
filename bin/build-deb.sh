#!/bin/sh
# KubeOS package builder: one predictable way to turn a package repo into a .deb.
#
# WHEN   in a release workflow, or by hand on the builder VM from inside a KubeOS package
#        repository checkout:
#            bin/build-deb.sh              # binary-only, unsigned (the archive signs instead)
#            bin/build-deb.sh --source     # also produce the .dsc/.tar.xz set
# WHY    `dpkg-buildpackage` has enough flags to get wrong that every repo would invent its
#        own invocation. This one is fixed: build the current tree, do not sign per package
#        (the archive's signed Release is what a node trusts), and leave the artefacts one
#        directory up, where archive-publish.sh looks for them.
# SAFE   Writes only ../*.deb|*.dsc|*.buildinfo next to the tree plus debian/ build output.
#        It never installs anything and never touches a node.
set -eu

FULL=0
case ${1:-} in
    --source) FULL=1 ;;
    '') : ;;
    *) printf 'build-deb: unknown argument: %s (try --source)\n' "$1" >&2; exit 2 ;;
esac

log() { printf 'build-deb: %s\n' "$*"; }
die() { printf 'build-deb: ERROR: %s\n' "$*" >&2; exit 1; }

[ -f debian/control ] || die "no debian/control here - run this from a package repository root"
command -v dpkg-buildpackage >/dev/null 2>&1 || die "dpkg-buildpackage is not installed"
command -v dpkg-checkbuilddeps >/dev/null 2>&1 || die "dpkg-dev is not installed"
dpkg-checkbuilddeps || die "install the Build-Depends first (see debian/control)"

PKG=$(sed -n 's/^Source:[[:space:]]*//p' debian/control | head -n 1)
VER=$(sed -n '1s/.*(\(.*\)).*/\1/p' debian/changelog)
log "building ${PKG:-?} ${VER:-?}"

if [ "$FULL" = 1 ]; then
    dpkg-buildpackage -sa -us -uc
else
    dpkg-buildpackage -b -us -uc
fi

log "artefacts (one directory up):"
for f in ../*.deb ../*.dsc ../*.buildinfo; do
    [ -e "$f" ] && printf '  %s\n' "$f"
done
exit 0
