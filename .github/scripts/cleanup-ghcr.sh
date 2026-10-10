#!/usr/bin/env bash
# Delete old versions of this repository's GHCR packages, keeping the newest
# KEEP versions of every package. Intended for a scheduled workflow.
#
# When a package version is deleted, the GitHub Release (and its git tag) that
# points to it is deleted too, and the entry is removed from the rolling
# `catalog` release. This avoids dead one-liners that would 404.
#
# GITHUB_TOKEN cannot delete package versions, so this needs a token with the
# `delete:packages` scope (a classic PAT) in the GHCR_GC_TOKEN secret.
# Release and catalog changes use RELEASE_TOKEN (the workflow GITHUB_TOKEN with
# contents: write). If RELEASE_TOKEN is unset, GH_TOKEN is used for both.
#
# Env:
#   GH_TOKEN           (required) PAT with delete:packages
#   RELEASE_TOKEN      token used for releases/catalog (default: GH_TOKEN)
#   GITHUB_REPOSITORY  (required) owner/repo
#   KEEP               versions to keep per package (default 5)
#   DRY_RUN            "1" to only list what would be deleted (default 0)
#   PACKAGE_PREFIX     only touch packages with this prefix (default macos-)
set -euo pipefail

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"
RELEASE_TOKEN=${RELEASE_TOKEN:-$GH_TOKEN}
owner=${GITHUB_REPOSITORY%%/*}
keep=${KEEP:-5}
dry_run=${DRY_RUN:-0}
prefix=${PACKAGE_PREFIX:-macos-}

deleted_tags_file=$(mktemp)
trap 'rm -f "$deleted_tags_file"' EXIT

# User packages and organization packages live under different endpoints.
owner_type=$(gh api "/users/${owner}" --jq .type 2>/dev/null || echo User)
if [ "$owner_type" = "Organization" ]; then
    base="/orgs/${owner}/packages"
else
    base="/users/${owner}/packages"
fi

echo "owner=${owner} type=${owner_type} keep=${keep} dry_run=${dry_run} prefix=${prefix}"

# Delete the GitHub Release and git tag that belong to a deleted package version.
delete_release() {
    local tag=$1
    if [ "$dry_run" = "1" ]; then
        echo "DRY-RUN release: would delete release and tag ${tag}"
        return 0
    fi
    if GH_TOKEN="$RELEASE_TOKEN" gh release view "$tag" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
        if GH_TOKEN="$RELEASE_TOKEN" gh release delete "$tag" --repo "$GITHUB_REPOSITORY" --cleanup-tag --yes >/dev/null 2>&1; then
            echo "deleted release ${tag}"
        else
            echo "::warning::failed to delete release ${tag}" >&2
        fi
    else
        echo "no release found for tag ${tag}"
    fi
}

# Remove deleted tags from catalog.json in the rolling `catalog` release.
update_catalog() {
    [ "$dry_run" = "1" ] && return 0
    [ -s "$deleted_tags_file" ] || return 0
    (
        export GH_TOKEN="$RELEASE_TOKEN"
        dir=$(mktemp -d)
        if ! gh release download catalog --repo "$GITHUB_REPOSITORY" \
            --pattern catalog.json --dir "$dir" --clobber >/dev/null 2>&1; then
            echo "no catalog release to update"
            rm -rf "$dir"
            exit 0
        fi
        gone=$(jq -R . "$deleted_tags_file" | jq -s .)
        jq --argjson gone "$gone" \
            '[ .[] | select(.tag as $t | ($gone | index($t)) | not) ]' \
            "$dir/catalog.json" > "$dir/catalog.new.json"
        mv "$dir/catalog.new.json" "$dir/catalog.json"
        gh release upload catalog "$dir/catalog.json" --repo "$GITHUB_REPOSITORY" --clobber
        echo "catalog updated"
        rm -rf "$dir"
    ) || echo "::warning::failed to update the 'catalog' release" >&2
}

packages=$(gh api --paginate "${base}?package_type=container&per_page=100" --jq '.[].name' 2>/dev/null || true)
if [ -z "$packages" ]; then
    echo "No container packages found (or the token lacks access)."
    exit 0
fi

total_deleted=0
for package in $packages; do
    case "$package" in
        "${prefix}"*) ;;
        *) continue ;;
    esac

    # Newest first. Output: "<id><TAB><created_at><TAB><comma-separated tags>".
    versions=$(gh api --paginate "${base}/container/${package}/versions?per_page=100" \
        --jq 'sort_by(.created_at) | reverse | .[] | "\(.id)\t\(.created_at)\t\([.metadata.container.tags[]?] | join(","))"' 2>/dev/null || true)
    [ -n "$versions" ] || { echo "${package}: no versions"; continue; }

    count=0
    kept=0
    while IFS=$'\t' read -r version_id created_at tags; do
        [ -n "$version_id" ] || continue
        count=$((count + 1))
        if [ "$count" -le "$keep" ]; then
            kept=$((kept + 1))
            continue
        fi
        if [ "$dry_run" = "1" ]; then
            echo "DRY-RUN ${package}: would delete version ${version_id} (${created_at}) tags='${tags}'"
            if [ -n "$tags" ]; then
                IFS=',' read -ra tag_list <<< "$tags"
                for t in "${tag_list[@]}"; do
                    delete_release "$t"
                done
            fi
        else
            if gh api -X DELETE "${base}/container/${package}/versions/${version_id}" >/dev/null 2>&1; then
                echo "deleted ${package}: version ${version_id} (${created_at}) tags='${tags}'"
                total_deleted=$((total_deleted + 1))
                # Only remove the release after the package version is really gone.
                if [ -n "$tags" ]; then
                    IFS=',' read -ra tag_list <<< "$tags"
                    for t in "${tag_list[@]}"; do
                        delete_release "$t"
                        printf '%s\n' "$t" >> "$deleted_tags_file"
                    done
                fi
            else
                echo "::warning::failed to delete ${package} version ${version_id}" >&2
            fi
        fi
    done <<< "$versions"

    echo "${package}: ${count} version(s), kept ${kept} newest"
done

update_catalog

echo "done (deleted=${total_deleted}, dry_run=${dry_run})"
