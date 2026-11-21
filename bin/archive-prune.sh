#!/bin/sh
# KubeOS archive: delete pool objects that no index entry names ("orphans").
#
# WHEN   After publishing a new version: archive-publish.sh keeps only the NEWEST stanza of a
#        package in the index, but it never removes the older .deb from the pool, so every release
#        leaves a file behind that apt can no longer reach. Measured 2026-11-22: 63 objects in the
#        pool, 19 in the index, 44 orphans, 583.8 MB - including two linux-image-kubeos builds
#        (1kubeos1/1kubeos2) that produced an ISO with no initramfs.
#
#            archive-prune.sh            # list what would go, delete nothing
#            KUBEOS_PRUNE_CONFIRM=1 archive-prune.sh   # delete it
#
# WHY    An orphan is not harmless: it costs storage, it makes "which versions exist?" unanswerable
#        from the pool alone, and it invites someone to install a version the project has withdrawn.
#        It cannot break `apt upgrade`, because the index never named it. What it can break is a
#        hand-pinned `apt install pkg=old-version` - which is exactly the point of removing it.
#
# SAFE   Read-only unless KUBEOS_PRUNE_CONFIRM=1. It only ever deletes a pool object whose path is
#        NOT in the index it just downloaded, never touches dists/, and re-verifies afterwards that
#        every remaining object is still indexed. Re-runnable.
#
# ENV    KUBEOS_ARCHIVE_REMOTE (default r2:kubeos-repo), KUBEOS_ARCHIVE_SUITE (trixie),
#        KUBEOS_ARCHIVE_COMPONENT (main), KUBEOS_ARCHIVE_ARCH (amd64),
#        KUBEOS_PRUNE_CONFIRM=1 to delete, KUBEOS_PRUNE_KEEP=<regex> to keep matching paths.
set -eu

SUITE=${KUBEOS_ARCHIVE_SUITE:-trixie}
COMPONENT=${KUBEOS_ARCHIVE_COMPONENT:-main}
ARCH=${KUBEOS_ARCHIVE_ARCH:-amd64}
REMOTE=${KUBEOS_ARCHIVE_REMOTE:-r2:kubeos-repo}
CONFIRM=${KUBEOS_PRUNE_CONFIRM:-0}
KEEP=${KUBEOS_PRUNE_KEEP:-}
INDEX_DIR="dists/$SUITE/$COMPONENT/binary-$ARCH"

log() { printf 'archive-prune: %s\n' "$*"; }
die() { printf 'archive-prune: ERROR: %s\n' "$*" >&2; exit 1; }

command -v rclone >/dev/null 2>&1 || die "rclone is not installed"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- 1. what the index names -------------------------------------------------------
rclone cat "$REMOTE/$INDEX_DIR/Packages" > "$WORK/index.raw" 2>/dev/null \
    || die "cannot read $INDEX_DIR/Packages from $REMOTE"
sed -n 's/^Filename: //p' "$WORK/index.raw" | sort -u > "$WORK/indexed"
[ -s "$WORK/indexed" ] || die "the index names no files; refusing to treat the whole pool as orphaned"
log "index names $(wc -l < "$WORK/indexed") file(s)"

# --- 2. what the pool holds (rclone lists paths relative to the given prefix) -------
rclone lsl "$REMOTE/pool" 2>/dev/null | awk '{ size = $1; path = "pool/" $4; print size, path }' > "$WORK/pool"

awk '{ print $2 }' "$WORK/pool" | sort -u > "$WORK/paths"
comm -23 "$WORK/paths" "$WORK/indexed" > "$WORK/orphans"

if [ -n "$KEEP" ]; then
    grep -vE "$KEEP" "$WORK/orphans" > "$WORK/orphans.kept" || true
    log "KUBEOS_PRUNE_KEEP=$KEEP keeps $(($(wc -l < "$WORK/orphans") - $(wc -l < "$WORK/orphans.kept"))) file(s)"
    mv "$WORK/orphans.kept" "$WORK/orphans"
fi

if [ ! -s "$WORK/orphans" ]; then
    log "no orphans: every object in the pool is named by the index"
    exit 0
fi

# --- 3. report, with sizes and a total ---------------------------------------------
total=0
log "orphans (in the pool, named by no index entry):"
while read -r path; do
    size=$(awk -v p="$path" '$2 == p { print $1; exit }' "$WORK/pool")
    total=$((total + size))
    printf '  %10s  %s\n' "$size" "$path"
done < "$WORK/orphans"
log "$(wc -l < "$WORK/orphans") orphan(s), $(awk -v t="$total" 'BEGIN { printf "%.1f", t/1048576 }') MB"

if [ "$CONFIRM" != 1 ]; then
    log "nothing deleted: set KUBEOS_PRUNE_CONFIRM=1 to delete these"
    exit 0
fi

# --- 4. delete, one path at a time, stop on the first failure ----------------------
failed=0
while read -r path; do
    if rclone deletefile --s3-no-check-bucket "$REMOTE/$path" >/dev/null 2>&1; then
        printf '  deleted %s\n' "$path"
    else
        printf '  FAILED  %s\n' "$path" >&2
        failed=$((failed + 1))
    fi
done < "$WORK/orphans"
[ "$failed" -eq 0 ] || die "$failed deletion(s) failed; re-run to retry them"

# --- 5. prove the pool now contains only indexed objects ---------------------------
rclone lsl "$REMOTE/pool" 2>/dev/null | awk '{ path = "pool/" $4; print path }' | sort -u > "$WORK/paths.after"
comm -23 "$WORK/paths.after" "$WORK/indexed" > "$WORK/left"
if [ -s "$WORK/left" ]; then
    die "the pool still holds $(wc -l < "$WORK/left") unindexed object(s): $(tr '\n' ' ' < "$WORK/left")"
fi
log "done: the pool holds exactly the $(wc -l < "$WORK/indexed") object(s) the index names"
exit 0
