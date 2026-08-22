#!/usr/bin/env bash
#
# Regenerates TripDataHub.xcodeproj from project.yml without churning the shared scheme.
#
# Use this instead of a bare `xcodegen generate`.
#
# ── Why this wrapper exists ────────────────────────────────────────────────────
#
# XcodeGen owns the whole `xcshareddata/xcschemes` directory. `ProjectGenerator`
# always constructs an `XCSharedData`, and `XcodeProj.writeSharedData` deletes every
# existing scheme before writing its own ("If true will remove all existing schemes
# before writing"). That leaves two bad options and no good one:
#
#   * Keep `scheme:` in project.yml  -> XcodeGen rewrites TripDataHub.xcscheme on every
#     run with its own boilerplate: LastUpgradeVersion 2650 -> 1430, scheme format
#     1.3 -> 1.7, plus runPostActionsOnFailure / onlyGenerateCoverageForSpecifiedTargets /
#     parallelizable / empty <CommandLineArguments> blocks. All cosmetic, all noise in
#     every diff, and it downgrades LastUpgradeVersion against the Xcode actually in use.
#
#   * Drop `scheme:` from project.yml -> XcodeGen generates zero schemes, and the delete
#     step then removes the committed scheme entirely. Worse.
#
# XcodeGen 2.46.0 has no flag to leave schemes alone, and the boilerplate above is
# hardcoded in XcodeProj's scheme writer, so a project.yml `schemes:` definition cannot
# reproduce the committed file byte-for-byte either.
#
# So: snapshot the schemes directory, generate, put the snapshot back. The snapshot is
# taken from disk (not from git), so uncommitted scheme edits survive too.
#
# The `scheme:` block stays in project.yml on purpose. It is the declarative record of
# which test targets belong to the scheme, and the fallback that regenerates a working
# scheme if the committed one is ever lost — delete the scheme file, run this script,
# and XcodeGen recreates it.
#
# ── Effect ─────────────────────────────────────────────────────────────────────
#
#   project.pbxproj                     regenerated from project.yml
#   xcshareddata/xcschemes/*.xcscheme   preserved exactly as they were on disk
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="${REPO_ROOT}/TripDataHub.xcodeproj"
SCHEMES_DIR="${PROJECT}/xcshareddata/xcschemes"

cd "${REPO_ROOT}"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen not found on PATH (expected >= 2.44.0; verified with 2.46.0)" >&2
    echo "       brew install xcodegen" >&2
    exit 1
fi

BACKUP_DIR=""

restore_schemes_and_cleanup() {
    local restore_status=0
    local cleanup_status=0

    if [[ -z "${BACKUP_DIR}" ]]; then
        return 0
    fi

    mkdir -p "${SCHEMES_DIR}" || restore_status=$?
    if (( restore_status == 0 )); then
        # Remove XcodeGen's freshly written schemes before restoring, so a scheme that was
        # deleted from the snapshot does not linger.
        find "${SCHEMES_DIR}" -maxdepth 1 -name '*.xcscheme' -delete || restore_status=$?
    fi
    if (( restore_status == 0 )); then
        cp -R "${BACKUP_DIR}/." "${SCHEMES_DIR}/" || restore_status=$?
    fi

    rm -rf -- "${BACKUP_DIR}" || cleanup_status=$?
    BACKUP_DIR=""

    if (( restore_status != 0 )); then
        echo "error: failed to restore shared schemes (status ${restore_status})" >&2
    fi
    if (( cleanup_status != 0 )); then
        echo "error: failed to remove the temporary scheme backup (status ${cleanup_status})" >&2
    fi
    if (( restore_status != 0 || cleanup_status != 0 )); then
        return 1
    fi

    return 0
}

cleanup_on_exit() {
    local original_status=$?
    local cleanup_status=0

    # Avoid recursively invoking this handler if cleanup itself exits unexpectedly.
    trap - EXIT
    set +e
    restore_schemes_and_cleanup
    cleanup_status=$?

    if (( cleanup_status != 0 )); then
        if (( original_status != 0 )); then
            echo "error: project generation failed with status ${original_status}; scheme restoration also failed" >&2
            exit "${original_status}"
        fi
        exit "${cleanup_status}"
    fi

    exit "${original_status}"
}

trap cleanup_on_exit EXIT

if [[ -d "${SCHEMES_DIR}" ]]; then
    BACKUP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tripdatahub-xcodegen.XXXXXX")"
    cp -R "${SCHEMES_DIR}/." "${BACKUP_DIR}/"
    echo "==> Snapshotted $(find "${BACKUP_DIR}" -name '*.xcscheme' | wc -l | tr -d ' ') shared scheme(s)"
fi

echo "==> xcodegen generate"
xcodegen generate

if [[ -n "${BACKUP_DIR}" ]]; then
    restore_schemes_and_cleanup
    echo "==> Restored shared scheme(s); xcscheme files are unchanged"
fi

echo
echo "==> Done. Expected git diff: project.pbxproj only."
git -C "${REPO_ROOT}" diff --stat -- \
    TripDataHub.xcodeproj/project.pbxproj \
    TripDataHub.xcodeproj/xcshareddata 2>/dev/null || true
