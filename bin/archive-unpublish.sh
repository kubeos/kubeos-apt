#!/bin/sh
# KubeOS archive: remove ONE published version of a package, safely.
#
# WHEN   A package version must disappear from https://repo.kubeos.in - typically a build that
#        never worked (2026-11-22: linux-image-kubeos 1kubeos1 and 1kubeos2, which produced an
#        ISO with no initramfs) or an accidental upload. Usage:
#            archive-unpublish.sh <package> <version>
#
# WHY    `apt` breaks for everyone if an index names a file that is not there, and a file left in
#        the pool keeps costing storage and keeps looking like a supported version. So the order
#        below is not negotiable: rewrite the index and sign it FIRST, prove the CDN serves the new
#        index, and only then delete the .deb from the pool. Deleting first would leave a window in
#        which any client with a cached index gets a 404 on a package it was just told about.
#
# SAFE   Re-runnable: an already-absent version is reported and exits 0. It refuses to remove the
#        LAST remaining version of a package (that would break every `Depends:` and `apt install`
#        on a node) unless KUBEOS_UNPUBLISH_ALLOW_EMPTY=1 is set deliberately. It never touches
#        dists/ files other than the three signatures it regenerates, and never touches /pool for
#        another package.
#
# ENV    same as archive-publish.sh:
#          KUBEOS_ARCHIVE_REMOTE       rclone remote:path of the bucket root (default r2:kubeos-repo)
#          KUBEOS_ARCHIVE_SUITE        suite (default trixie)
#          KUBEOS_ARCHIVE_COMPONENT    component (default main)
#          KUBEOS_ARCHIVE_ARCH         architecture (default amd64)
#          KUBEOS_GPG_KEY              signing key id or uid (default: default key)
#          KUBEOS_GPG_PASSPHRASE_FILE  file holding its passphrase
#          KUBEOS_ARCHIVE_URL          public base URL; when set, every upload is re-read over HTTPS
#          KUBEOS_PUBLISH_DRY_RUN      1 = show what would change, write nothing
set -eu

SUITE=${KUBEOS_ARCHIVE_SUITE:-trixie}
COMPONENT=${KUBEOS_ARCHIVE_COMPONENT:-main}
ARCH=${KUBEOS_ARCHIVE_ARCH:-amd64}
REMOTE=${KUBEOS_ARCHIVE_REMOTE:-r2:kubeos-repo}
GPG_KEY=${KUBEOS_GPG_KEY:-}
DRY_RUN=${KUBEOS_PUBLISH_DRY_RUN:-0}
ARCHIVE_URL=${KUBEOS_ARCHIVE_URL:-}
ALLOW_EMPTY=${KUBEOS_UNPUBLISH_ALLOW_EMPTY:-0}

INDEX_DIR="dists/$SUITE/$COMPONENT/binary-$ARCH"

log() { printf 'archive-unpublish: %s\n' "$*"; }
die() { printf 'archive-unpublish: ERROR: %s\n' "$*" >&2; exit 1; }

[ $# -eq 2 ] || die "usage: $0 <package> <version>   (both required: removing a package by version is the only safe grain)"
PKG=$1
VER=$2

for tool in rclone apt-ftparchive gpg gzip curl; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed"
done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- 1. the index as it is now -----------------------------------------------------
rclone copyto --s3-no-check-bucket "$REMOTE/$INDEX_DIR/Packages" "$WORK/Packages" >/dev/null 2>&1 \
    || die "cannot read $INDEX_DIR/Packages from $REMOTE (has anything been published yet?)"
[ -s "$WORK/Packages" ] || die "$INDEX_DIR/Packages is empty"

# --- 2. the stanza to remove, and the pool file it names ---------------------------
awk -v want="$PKG" -v ver="$VER" '
    BEGIN { RS = ""; ORS = "\n\n" }
    {
        p = ""
        v = ""
        n = split($0, line, "\n")
        for (i = 1; i <= n; i++) {
            if (line[i] == "Package: " want) p = want
            if (line[i] == "Version: " ver) v = ver
        }
        if (p == want && v == ver) print
    }
' "$WORK/Packages" > "$WORK/doomed"

if [ ! -s "$WORK/doomed" ]; then
    log "$PKG $VER is not in the index (nothing to do)"
    exit 0
fi

POOL_FILE=$(sed -n 's/^Filename: //p' "$WORK/doomed" | head -n 1)
[ -n "$POOL_FILE" ] || die "the stanza for $PKG $VER has no Filename field; refusing to guess"
log "removing $PKG $VER"
log "  index stanza: $WORK/doomed"
log "  pool object : $POOL_FILE"

# --- 3. refuse to empty a package out of the archive -------------------------------
REMAINING=$(awk -v want="$PKG" -v ver="$VER" '
    BEGIN { RS = "" }
    {
        p = 0
        v = 0
        n = split($0, line, "\n")
        for (i = 1; i <= n; i++) {
            if (line[i] == "Package: " want) p = 1
            if (line[i] == "Version: " ver) v = 1
        }
        if (p && !v) kept++
    }
    END { print kept + 0 }
' "$WORK/Packages")
if [ "$REMAINING" -eq 0 ] && [ "$ALLOW_EMPTY" != 1 ]; then
    die "$PKG $VER is the ONLY version of $PKG in this archive; removing it would break every Depends:/apt install that names $PKG. Set KUBEOS_UNPUBLISH_ALLOW_EMPTY=1 only if that is what you mean."
fi
log "  versions of $PKG that stay: $REMAINING"

# --- 4. the new index --------------------------------------------------------------
awk -v want="$PKG" -v ver="$VER" '
    BEGIN { RS = ""; ORS = "\n\n" }
    {
        p = 0
        v = 0
        n = split($0, line, "\n")
        for (i = 1; i <= n; i++) {
            if (line[i] == "Package: " want) p = 1
            if (line[i] == "Version: " ver) v = 1
        }
        if (!(p && v)) print
    }
' "$WORK/Packages" > "$WORK/Packages.new"
[ -s "$WORK/Packages.new" ] || die "the new index would be empty; refusing"
gzip -9 -nc "$WORK/Packages.new" > "$WORK/Packages.gz"

mkdir -p "$WORK/dists/$SUITE/$COMPONENT/binary-$ARCH"
cp "$WORK/Packages.new" "$WORK/dists/$SUITE/$COMPONENT/binary-$ARCH/Packages"
cp "$WORK/Packages.gz" "$WORK/dists/$SUITE/$COMPONENT/binary-$ARCH/Packages.gz"

# --- 5. Release + signatures, exactly like archive-publish.sh ----------------------
(
    cd "$WORK/dists/$SUITE" || exit 1
    apt-ftparchive \
        -o APT::FTPArchive::Release::Origin=KubeOS \
        -o APT::FTPArchive::Release::Label=KubeOS \
        -o APT::FTPArchive::Release::Suite="$SUITE" \
        -o APT::FTPArchive::Release::Codename="$SUITE" \
        -o APT::FTPArchive::Release::Architectures="$ARCH" \
        -o APT::FTPArchive::Release::Components="$COMPONENT" \
        -o APT::FTPArchive::Release::Description="KubeOS package archive" \
        release .
) > "$WORK/Release" || die "apt-ftparchive release failed"
[ -s "$WORK/Release" ] || die "empty Release file"

SIGN_ARGS="--batch --yes --digest-algo SHA256"
[ -n "$GPG_KEY" ] && SIGN_ARGS="$SIGN_ARGS --local-user $GPG_KEY"
if [ -n "${KUBEOS_GPG_PASSPHRASE_FILE:-}" ]; then
    [ -r "$KUBEOS_GPG_PASSPHRASE_FILE" ] || die "cannot read $KUBEOS_GPG_PASSPHRASE_FILE"
    SIGN_ARGS="$SIGN_ARGS --pinentry-mode loopback --passphrase-file $KUBEOS_GPG_PASSPHRASE_FILE"
fi
# shellcheck disable=SC2086  # SIGN_ARGS is deliberately word-split
gpg $SIGN_ARGS --armor --detach-sign -o "$WORK/Release.gpg" "$WORK/Release" \
    || die "detached signature failed (is the archive key imported?)"
# shellcheck disable=SC2086
gpg $SIGN_ARGS --clearsign -o "$WORK/InRelease" "$WORK/Release" || die "clearsign failed"

upload() {   # upload LOCAL REMOTE_PATH CACHE_CONTROL
    if [ "$DRY_RUN" = 1 ]; then
        log "would upload $2 ($3)"
        return 0
    fi
    rclone copyto --s3-no-check-bucket --s3-disable-checksum \
        --header-upload "Cache-Control: $3" \
        "$1" "$REMOTE/$2" || die "upload failed: $2"
    log "uploaded $2 ($3)"
}

# --- 6. index first, then the file -------------------------------------------------
upload "$WORK/Packages.new" "$INDEX_DIR/Packages" "no-cache"
upload "$WORK/Packages.gz" "$INDEX_DIR/Packages.gz" "no-cache"
upload "$WORK/Release" "dists/$SUITE/Release" "no-cache"
upload "$WORK/Release.gpg" "dists/$SUITE/Release.gpg" "no-cache"
upload "$WORK/InRelease" "dists/$SUITE/InRelease" "no-cache"

[ "$DRY_RUN" = 1 ] && { log "dry run: nothing was uploaded and $POOL_FILE was NOT deleted"; exit 0; }

# prove the CDN already serves the new index before a file disappears from under it
if [ -n "$ARCHIVE_URL" ]; then
    want=$(sha256sum "$WORK/Packages.gz" | cut -d' ' -f1)
    got=""
    i=0
    while [ "$i" -lt 6 ]; do
        got=$(curl -fsS -m 20 "$ARCHIVE_URL/$INDEX_DIR/Packages.gz" 2>/dev/null | sha256sum | cut -d' ' -f1) || got=""
        [ "$got" = "$want" ] && break
        i=$((i + 1))
        [ "$i" -lt 6 ] && sleep 10
    done
    [ "$got" = "$want" ] || die "$INDEX_DIR/Packages.gz is NOT what the CDN serves yet (uploaded ${want}, served ${got:-nothing}). The .deb was NOT deleted - fix the cache rule for /dists/* and re-run."
    log "served OK: $INDEX_DIR/Packages.gz (the new index is live)"
fi

# --- 7. only now remove the pool object --------------------------------------------
rclone deletefile --s3-no-check-bucket "$REMOTE/$POOL_FILE" >/dev/null 2>&1 \
    || die "the index no longer lists it, but deleting $POOL_FILE failed - remove it by hand"
log "deleted $POOL_FILE"

if [ -n "$ARCHIVE_URL" ]; then
    code=$(curl -s -o /dev/null -m 20 -w '%{http_code}' "$ARCHIVE_URL/$POOL_FILE") || code="000"
    case "$code" in
        404) log "public URL is gone (404): $POOL_FILE" ;;
        *)   log "WARNING: the CDN still answers $code for $POOL_FILE (cached copy); it will expire" ;;
    esac
fi

COUNT=$(grep -c '^Package: ' "$WORK/Packages.new" || true)
log "unpublished $PKG $VER; the archive now lists $COUNT package(s) in $SUITE/$COMPONENT/$ARCH"
exit 0
