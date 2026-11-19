#!/bin/sh
# KubeOS archive publisher: add one built .deb to the signed APT archive.
#
# WHEN   at the end of a package repository's release workflow, or by hand on the builder
#        VM after `dpkg-buildpackage`:
#            bin/archive-publish.sh ../kubeos-cli_1.0.0-1kubeos1_amd64.deb
# WHY    The archive is a static tree in a Cloudflare R2 bucket, so nothing indexes it for us.
#        This script is the only thing that may touch it: it copies the payload, merges the
#        one stanza that changed into `Packages`, regenerates `Release` from the files that
#        exist, signs it with the KubeOS archive key, and uploads in an order that never leaves
#        a node looking at an index that names a missing file.
# SAFE   Re-runnable: publishing the same version again replaces its stanza and re-signs.
#        It only ever writes under the pool path of the package it was given, it refuses a
#        foreign package or architecture, and dry-run writes nothing at all.
#
# Environment:
#   KUBEOS_ARCHIVE_REMOTE       rclone remote:path of the bucket root  (default r2:kubeos-repo)
#   KUBEOS_ARCHIVE_SUITE        suite/codename to publish into         (default trixie)
#   KUBEOS_ARCHIVE_COMPONENT    component                              (default main)
#   KUBEOS_ARCHIVE_ARCH         Debian architecture                    (default amd64)
#   KUBEOS_GPG_KEY              signing key id or uid                  (default: default key)
#   KUBEOS_GPG_PASSPHRASE_FILE  file holding its passphrase (unattended signing)
#   KUBEOS_PUBLISH_DRY_RUN      1 = print what would be uploaded, write nothing
set -eu

REMOTE=${KUBEOS_ARCHIVE_REMOTE:-r2:kubeos-repo}
SUITE=${KUBEOS_ARCHIVE_SUITE:-trixie}
COMPONENT=${KUBEOS_ARCHIVE_COMPONENT:-main}
ARCH=${KUBEOS_ARCHIVE_ARCH:-amd64}
GPG_KEY=${KUBEOS_GPG_KEY:-}
DRY_RUN=${KUBEOS_PUBLISH_DRY_RUN:-0}

INDEX_DIR="dists/$SUITE/$COMPONENT/binary-$ARCH"

log() { printf 'archive-publish: %s\n' "$*"; }
die() { printf 'archive-publish: ERROR: %s\n' "$*" >&2; exit 1; }

[ $# -eq 1 ] || die "usage: $0 <file.deb>"
DEB=$1
[ -f "$DEB" ] || die "no such file: $DEB"

for tool in rclone dpkg-deb apt-ftparchive gpg gzip; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed"
done

PKG=$(dpkg-deb -f "$DEB" Package)
VER=$(dpkg-deb -f "$DEB" Version)
DEB_ARCH=$(dpkg-deb -f "$DEB" Architecture)
[ -n "$PKG" ] && [ -n "$VER" ] || die "$DEB has no Package/Version field"
[ "$DEB_ARCH" = "$ARCH" ] || die "$DEB is $DEB_ARCH, this archive publishes $ARCH"

case "$PKG" in
    kubeos-*) : ;;
    *) die "$PKG is not a KubeOS package (refusing to publish foreign content)" ;;
esac

LETTER=$(printf '%s' "$PKG" | cut -c1)
POOL_PATH="pool/$COMPONENT/$LETTER/$PKG/$(basename "$DEB")"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

upload() {   # upload LOCAL REMOTE_PATH CACHE_CONTROL
    if [ "$DRY_RUN" = 1 ]; then
        log "would upload $2 ($3)"
        return 0
    fi
    rclone copyto --s3-no-check-bucket --header-upload "Cache-Control: $3" \
        "$1" "$REMOTE/$2" || die "upload failed: $2"
    log "uploaded $2 ($3)"
}

fetch() {    # fetch REMOTE_PATH LOCAL_PATH - 0 only when it really downloaded something
    [ "$DRY_RUN" = 1 ] && return 1
    rclone copyto --s3-no-check-bucket "$REMOTE/$1" "$2" >/dev/null 2>&1
}

log "publishing $PKG $VER ($DEB_ARCH) to $REMOTE"

# --- 1. payload first: the index may only name a file that already exists -----------
upload "$DEB" "$POOL_PATH" "public, max-age=31536000, immutable"

# --- 2. index: merge the one stanza that changed -----------------------------------
mkdir -p "$WORK/tree/$(dirname "$POOL_PATH")"
cp "$DEB" "$WORK/tree/$POOL_PATH"
( cd "$WORK/tree" && apt-ftparchive packages -- "$POOL_PATH" ) > "$WORK/stanza"
[ -s "$WORK/stanza" ] || die "apt-ftparchive produced no stanza for $DEB"

if fetch "$INDEX_DIR/Packages" "$WORK/Packages"; then
    log "merging into the existing index"
else
    : > "$WORK/Packages"
    log "no existing index: this is the first publish into $SUITE/$COMPONENT"
fi

# Drop every stanza of THIS package (one version per package per architecture), append
# the new one. RS="" is awk's paragraph mode, so a record is exactly one stanza.
{
    awk -v want="$PKG" '
        BEGIN { RS = ""; ORS = "\n\n" }
        {
            keep = 1
            n = split($0, line, "\n")
            for (i = 1; i <= n; i++) {
                if (line[i] == "Package: " want) { keep = 0; break }
            }
            if (keep) print
        }
    ' "$WORK/Packages"
    cat "$WORK/stanza"
} > "$WORK/Packages.raw" || die "index merge failed"

# Exactly one blank line between stanzas, one trailing newline.
awk 'BEGIN { RS = ""; ORS = "\n\n" } { print }' "$WORK/Packages.raw" > "$WORK/Packages.new"
gzip -9 -nc "$WORK/Packages.new" > "$WORK/Packages.gz"

mkdir -p "$WORK/dists/$SUITE/$COMPONENT/binary-$ARCH"
cp "$WORK/Packages.new" "$WORK/dists/$SUITE/$COMPONENT/binary-$ARCH/Packages"
cp "$WORK/Packages.gz" "$WORK/dists/$SUITE/$COMPONENT/binary-$ARCH/Packages.gz"

# --- 3. Release, generated from the index that exists, then signed -----------------
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

# --- 4. publish the index in the order a client can follow ------------------------
upload "$WORK/Packages.new" "$INDEX_DIR/Packages" "no-cache"
upload "$WORK/Packages.gz" "$INDEX_DIR/Packages.gz" "no-cache"
upload "$WORK/Release" "dists/$SUITE/Release" "no-cache"
upload "$WORK/Release.gpg" "dists/$SUITE/Release.gpg" "no-cache"
upload "$WORK/InRelease" "dists/$SUITE/InRelease" "no-cache"

[ "$DRY_RUN" = 1 ] && { log "dry run: nothing was uploaded"; exit 0; }

# --- 5. prove what a node will actually see ---------------------------------------
fetch "dists/$SUITE/InRelease" "$WORK/InRelease.remote" || die "InRelease is unreadable after upload"
gpg --verify "$WORK/InRelease.remote" >/dev/null 2>&1 \
    || die "the published InRelease does not verify against the local keyring"

COUNT=$(grep -c '^Package: ' "$WORK/Packages.new" || true)
log "published $PKG $VER; the archive lists $COUNT package(s) in $SUITE/$COMPONENT/$ARCH"
log "a node picks it up with: apt update && apt upgrade"
exit 0
