#!/bin/bash

set -e

# Generate GitHub release for a Godot version and upload artifacts.
#
# Usage: ./upload-github.sh -v 3.6
# Usage: ./upload-github.sh -v 3.6 -f beta3
# Usage: ./upload-github.sh -v 3.6 -f beta3 -r owner/repository
#
# Run this script from the root of the godot-build-scripts folder
# after building Godot.
#
# The publication is resumable. Release metadata, tags, and GitHub releases
# which already exist are verified against the expected release and reused,
# assets which are already part of the release are skipped, and only the
# missing ones are uploaded. Any state which cannot be verified (a tag pointing
# at another commit, a release attached to another tag, an asset with an
# unexpected size) is reported as an error instead of being overwritten, so a
# failed upload can be resumed by simply running this script again.

# Folder this script is called from, a.k.a its working directory.
basedir=$(pwd)
export basedir

# Folder where this scripts resides in.
scriptpath=$(readlink -f "$0")
scriptdir=$(dirname "$scriptpath")
# Root folder of this project, hopefully.
buildsdir=$(dirname "$scriptdir")
export buildsdir

if [ ! -d "${basedir}/releases" ] || [ ! -d "${basedir}/tmp" ]; then
  echo "Cannot find one of the required folders: releases, tmp."
  echo "  Make sure you're running this script from the root of your godot-build-scripts clone, and that Godot has been built with it."
  exit 1
fi

# Setup.

godot_version=""
godot_flavor="stable"
godot_repository="godotengine/godot-builds"
draft=0

while getopts "v:f:r:d" opt; do
  case "$opt" in
  v)
    godot_version=$OPTARG
    ;;
  f)
    godot_flavor=$OPTARG
    ;;
  r)
    godot_repository=$OPTARG
    ;;
  d)
    draft=1
    ;;
  \?)
    echo "Unknown option: -$OPTARG" >&2
    exit 1
    ;;
  esac
done

release_tag="$godot_version-$godot_flavor"

echo "Preparing release $release_tag..."

version_path="$basedir/releases/$release_tag"
if [ ! -d "${version_path}" ]; then
  echo "Cannot find the release folder at $version_path."
  echo "  Make sure you're running this script from the root of godot-build-scripts, and that Godot has been built."
  exit 1
fi

# The Godot source checkout identifies the commit this release is built from.
# It is recorded in the release metadata, so it is also needed to verify an
# existing release when resuming.
if [ ! -d "${basedir}/git" ]; then
  echo "Cannot find the Godot source checkout at ${basedir}/git."
  echo "  It is required to identify the commit this release is built from."
  exit 1
fi

git_reference=$(git -C "${basedir}/git" rev-parse HEAD)

metadata_relpath="releases/godot-${release_tag}.json"
metadata_path="${buildsdir}/${metadata_relpath}"

# create-release-metadata.py records the release tag instead of the git hash for
# stable releases, so the same rule applies when verifying existing metadata.
expected_name="$godot_version"
expected_reference="$git_reference"
if [ "$godot_flavor" != "stable" ]; then
  expected_name="${godot_version}-${godot_flavor}"
else
  expected_reference="${godot_version}-stable"
fi

# Scratch space for API responses and other temporary files.
scratchdir=$(mktemp -d)
cleanup() {
  rm -rf "$scratchdir"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Prints "<name>\t<git_reference>" for a release metadata file.
#
# Exits with 2 if the file cannot be read or parsed.
read_metadata_identity() {
  python3 - "$1" <<'PYEOF'
import json
import sys

path = sys.argv[1]

try:
    with open(path, "r", encoding="utf-8") as metadata_file:
        metadata = json.load(metadata_file)
except OSError as error:
    sys.stderr.write("Cannot read release metadata '%s': %s\n" % (path, error))
    sys.exit(2)
except ValueError as error:
    sys.stderr.write("Cannot parse release metadata '%s': %s\n" % (path, error))
    sys.exit(2)

print("%s\t%s" % (metadata.get("name", ""), metadata.get("git_reference", "")))
PYEOF
}

# Verifies that a release metadata file describes the release being published.
check_metadata_identity() {
  local metadata_file="$1"
  local origin="$2"
  local identity
  local found_name
  local found_reference

  if ! identity=$(read_metadata_identity "$metadata_file"); then
    echo "Cannot verify the release metadata from ${origin} (${metadata_file})." >&2
    exit 1
  fi

  found_name=${identity%%$'\t'*}
  found_reference=${identity#*$'\t'}

  if [ "$found_name" != "$expected_name" ] || [ "$found_reference" != "$expected_reference" ]; then
    echo "ERROR: Release metadata mismatch in ${origin} (${metadata_file}):" >&2
    echo "         expected: name '${expected_name}', git reference '${expected_reference}'" >&2
    echo "         found:    name '${found_name}', git reference '${found_reference}'" >&2
    echo "       Refusing to reuse it. If ${release_tag} was built from another commit, check" >&2
    echo "       out ${expected_reference} in ${basedir}/git, or remove the conflicting" >&2
    echo "       metadata before publishing." >&2
    exit 1
  fi
}

# Verifies that an existing tag points at a commit containing the release
# metadata of the release being published.
check_tag_target() {
  local tag_commit
  local tagged_metadata="${scratchdir}/tagged-metadata.json"

  if ! tag_commit=$(git -C "$buildsdir" rev-parse -q --verify "refs/tags/${release_tag}^{commit}"); then
    echo "ERROR: Tag ${release_tag} exists but does not resolve to a commit." >&2
    echo "       Refusing to reuse it; resolve the tag manually before publishing." >&2
    exit 1
  fi

  if ! git -C "$buildsdir" cat-file -e "${tag_commit}:${metadata_relpath}" 2>/dev/null; then
    echo "ERROR: Tag ${release_tag} points at ${tag_commit}, which does not contain ${metadata_relpath}." >&2
    echo "       Refusing to reuse it, as it cannot be matched to this release." >&2
    exit 1
  fi

  git -C "$buildsdir" show "${tag_commit}:${metadata_relpath}" > "$tagged_metadata"
  check_metadata_identity "$tagged_metadata" "the commit tagged ${release_tag} (${tag_commit})"

  echo "Reusing tag ${release_tag} at ${tag_commit}."
}

# Prints "<tag_name>\t<draft>\t<prerelease>" for a GitHub release.
#
# Exits with 2 if the release cannot be read, and with 3 if it is attached to
# another tag than the one being published.
read_release_identity() {
  python3 - "$1" "$2" <<'PYEOF'
import json
import sys

path, expected_tag = sys.argv[1], sys.argv[2]

try:
    with open(path, "r", encoding="utf-8") as release_file:
        release = json.load(release_file)
except OSError as error:
    sys.stderr.write("Cannot read the GitHub release information from '%s': %s\n" % (path, error))
    sys.exit(2)
except ValueError as error:
    sys.stderr.write("Cannot parse the GitHub release information from '%s': %s\n" % (path, error))
    sys.exit(2)

tag_name = release.get("tag_name")
if tag_name != expected_tag:
    sys.stderr.write("ERROR: The GitHub release found for '%s' is attached to tag '%s'.\n" % (expected_tag, tag_name))
    sys.stderr.write("       Refusing to reuse it, as it is not the release for %s.\n" % expected_tag)
    sys.exit(3)

print("%s\t%s\t%s" % (
    tag_name,
    str(release.get("draft")).lower(),
    str(release.get("prerelease")).lower(),
))
PYEOF
}

# Prints the assets of a GitHub release as "<name>\t<size>" lines.
read_release_assets() {
  python3 - "$1" <<'PYEOF'
import json
import sys

path = sys.argv[1]

try:
    with open(path, "r", encoding="utf-8") as release_file:
        release = json.load(release_file)
except (OSError, ValueError) as error:
    sys.stderr.write("Cannot read the assets of the GitHub release: %s\n" % error)
    sys.exit(2)

for asset in release.get("assets") or []:
    print("%s\t%s" % (asset.get("name", ""), asset.get("size", "")))
PYEOF
}

# Prints the size of an asset which is already part of the release, if any.
existing_asset_size() {
  awk -F'\t' -v asset_name="$1" '$1 == asset_name { print $2; exit }' "$assets_file"
}

# Uploads a file to the release, unless it is already part of it.
upload_asset() {
  local file_path="$1"
  local asset_name
  local local_size
  local existing_size

  asset_name=$(basename "$file_path")
  local_size=$(wc -c < "$file_path" | tr -d '[:space:]')
  existing_size=$(existing_asset_size "$asset_name")

  if [ -n "$existing_size" ]; then
    if [ "$existing_size" != "$local_size" ]; then
      echo "" >&2
      echo "ERROR: Asset '${asset_name}' is already part of release ${release_tag}, but its" >&2
      echo "       size (${existing_size} bytes) differs from the local file (${local_size} bytes" >&2
      echo "       at ${file_path})." >&2
      echo "       Refusing to overwrite it. If the published asset is known to be broken," >&2
      echo "       delete it with the following command, then run this script again:" >&2
      echo "         gh release delete-asset ${release_tag} \"${asset_name}\" -R ${godot_repository}" >&2
      exit 1
    fi

    echo "Skipping ${asset_name}: already uploaded (${local_size} bytes)."
    skipped_count=$((skipped_count + 1))
    return 0
  fi

  echo "Uploading ${asset_name}..."
  if ! gh release upload "$release_tag" "$file_path" -R "$godot_repository"; then
    echo "" >&2
    echo "Failed to upload ${asset_name} to release ${release_tag}." >&2
    echo "  Assets uploaded before this point have been kept. Re-run the same command to" >&2
    echo "  resume the publication: assets which are already part of the release are" >&2
    echo "  detected and skipped." >&2
    exit 1
  fi

  # Keep track of it, so a repeated filename is not uploaded twice.
  printf '%s\t%s\n' "$asset_name" "$local_size" >> "$assets_file"
  uploaded_count=$((uploaded_count + 1))
}

# ---------------------------------------------------------------------------
# 1. Release metadata
# ---------------------------------------------------------------------------

# The release metadata is only generated once: regenerating it would change its
# release date and create a duplicate commit on every re-run.

metadata_commit_created=0

if [ -f "$metadata_path" ]; then
  echo "Found existing release metadata at ${metadata_path}, verifying it..."

  check_metadata_identity "$metadata_path" "the working tree of ${buildsdir}"

  if git -C "$buildsdir" ls-files --error-unmatch "$metadata_relpath" > /dev/null 2>&1 &&
    git -C "$buildsdir" diff --quiet -- "$metadata_relpath"; then
    echo "Reusing committed release metadata for ${release_tag}."
  else
    # Generated by an interrupted run which never got to commit it.
    echo "Release metadata for ${release_tag} is not committed yet, committing it."
    metadata_commit_created=1
  fi
else
  echo "Creating and committing release metadata for ${release_tag}..."

  if ! "$buildsdir/tools/create-release-metadata.py" -v "$godot_version" -f "$godot_flavor" -g "$git_reference"; then
    echo "Failed to create release metadata for $release_tag."
    exit 1
  fi

  check_metadata_identity "$metadata_path" "the generated metadata"
  metadata_commit_created=1
fi

if [ "$metadata_commit_created" = "1" ]; then
  git -C "$buildsdir" add "$metadata_relpath"
  # Nothing to commit if the metadata was regenerated identically.
  if ! git -C "$buildsdir" diff --cached --quiet -- "$metadata_relpath"; then
    git -C "$buildsdir" commit -m "Add Godot $release_tag"
  fi
fi

# ---------------------------------------------------------------------------
# 2. State of the existing tag and GitHub release
# ---------------------------------------------------------------------------

# Everything in this section is read-only: nothing is created, moved, or
# deleted before both the tag and the release have been accounted for.

if ! remote_tag_listing=$(git -C "$buildsdir" ls-remote --tags --refs origin "refs/tags/${release_tag}" 2> "${scratchdir}/ls-remote-error.txt"); then
  echo "Failed to list the tags of the 'origin' remote in ${buildsdir}:" >&2
  cat "${scratchdir}/ls-remote-error.txt" >&2
  echo "  Refusing to continue: it is unknown whether the tag ${release_tag} exists." >&2
  exit 1
fi
remote_tag_sha=$(printf '%s\n' "$remote_tag_listing" | awk 'NF > 0 { print $1; exit }')

# Make sure the repository can be reached, so that a "not found" answer below
# really means "this release does not exist yet" and not a typo, a permission
# problem, or a network failure.
if ! gh api "repos/${godot_repository}" > "${scratchdir}/repository.json" 2> "${scratchdir}/repository-error.txt"; then
  echo "Cannot access repository ${godot_repository} with the GitHub CLI:" >&2
  cat "${scratchdir}/repository-error.txt" >&2
  echo "  Refusing to continue: it is unknown whether the release ${release_tag} exists." >&2
  exit 1
fi

release_json="${scratchdir}/release.json"
release_exists=0

if gh api "repos/${godot_repository}/releases/tags/${release_tag}" > "$release_json" 2> "${scratchdir}/release-error.txt"; then
  release_exists=1
elif grep -qi -e "not found" -e "HTTP 404" "${scratchdir}/release-error.txt"; then
  release_exists=0
else
  echo "Failed to look up the GitHub release ${release_tag} in ${godot_repository}:" >&2
  cat "${scratchdir}/release-error.txt" >&2
  echo "  Refusing to continue: it is unknown whether the release ${release_tag} exists." >&2
  exit 1
fi

if [ "$release_exists" = "1" ] && [ -z "$remote_tag_sha" ]; then
  echo "ERROR: A GitHub release exists for ${release_tag}, but the tag ${release_tag} is" >&2
  echo "       missing from the 'origin' remote of ${buildsdir}." >&2
  echo "       Refusing to guess which release is the right one; reconcile the tag and the" >&2
  echo "       release manually before publishing." >&2
  exit 1
fi

if [ "$release_exists" = "1" ]; then
  if ! release_info=$(read_release_identity "$release_json" "$release_tag"); then
    echo "Refusing to reuse the existing GitHub release ${release_tag} in ${godot_repository}." >&2
    exit 1
  fi

  echo "Reusing GitHub release ${release_tag} (draft: $(printf '%s' "$release_info" | cut -f2), prerelease: $(printf '%s' "$release_info" | cut -f3))."
fi

# ---------------------------------------------------------------------------
# 3. Release tag
# ---------------------------------------------------------------------------

# The tag is never moved: it is created, verified, or the script bails out.

local_tag_sha=""
need_push_tag=0

if local_tag_sha=$(git -C "$buildsdir" rev-parse -q --verify "refs/tags/${release_tag}"); then
  echo "Found tag ${release_tag} locally."
else
  local_tag_sha=""
fi

if [ -n "$local_tag_sha" ] && [ -n "$remote_tag_sha" ] && [ "$local_tag_sha" != "$remote_tag_sha" ]; then
  echo "ERROR: Tag ${release_tag} points at ${local_tag_sha} locally, but at" >&2
  echo "       ${remote_tag_sha} on 'origin'." >&2
  echo "       Refusing to move or overwrite it; resolve the difference manually." >&2
  exit 1
fi

if [ -z "$local_tag_sha" ] && [ -n "$remote_tag_sha" ]; then
  echo "Fetching tag ${release_tag} from 'origin'..."
  if ! git -C "$buildsdir" fetch origin "refs/tags/${release_tag}:refs/tags/${release_tag}" 2> "${scratchdir}/fetch-error.txt"; then
    echo "Failed to fetch tag ${release_tag} from 'origin':" >&2
    cat "${scratchdir}/fetch-error.txt" >&2
    exit 1
  fi
  check_tag_target
elif [ -z "$local_tag_sha" ] && [ -z "$remote_tag_sha" ]; then
  git -C "$buildsdir" tag "$release_tag"
  need_push_tag=1
  echo "Created tag ${release_tag}."
else
  check_tag_target
  if [ -z "$remote_tag_sha" ]; then
    # Created by an interrupted run which never got to push it.
    need_push_tag=1
  fi
fi

# ---------------------------------------------------------------------------
# 4. Publish the metadata and the tag
# ---------------------------------------------------------------------------

# The tag is pushed without forcing it, so an existing remote tag can only be
# pushed when it already matches the local one.

if [ "$need_push_tag" = "1" ]; then
  echo "Pushing release metadata and tag ${release_tag} to GitHub..."
  # The tagged commit may not be on the remote branch yet, so push both.
  if ! git -C "$buildsdir" push --atomic origin main "$release_tag"; then
    echo "Failed to push release metadata for $release_tag to GitHub."
    exit 1
  fi
elif [ "$metadata_commit_created" = "1" ]; then
  echo "Pushing release metadata for ${release_tag} to GitHub..."
  if ! git -C "$buildsdir" push origin main; then
    echo "Failed to push release metadata for $release_tag to GitHub."
    exit 1
  fi
else
  echo "Release metadata and tag ${release_tag} are already up to date on 'origin'."
fi

# Exactly one time it failed to create release immediately after pushing the tag,
# so we use this for protection...
sleep 2

# ---------------------------------------------------------------------------
# 5. GitHub release
# ---------------------------------------------------------------------------

assets_file="${scratchdir}/existing-assets.tsv"
uploaded_count=0
skipped_count=0

if [ "$release_exists" != "1" ]; then
  echo "Creating and publishing GitHub release for $release_tag..."

  if ! "$buildsdir/tools/create-release-notes.py" -v "$godot_version" -f "$godot_flavor" -g "$git_reference"; then
    echo "Failed to create release notes for $release_tag."
    exit 1
  fi

  release_notes="$basedir/tmp/release-notes-$release_tag.txt"
  release_flags=()
  if [ "$godot_flavor" != "stable" ]; then
    release_flags+=("--prerelease")
  fi
  if [ "$draft" == "1" ]; then
    release_flags+=("--draft")
  fi

  if ! gh release create "$release_tag" --verify-tag --title "$release_tag" --notes-file "$release_notes" "${release_flags[@]}" -R "$godot_repository"; then
    echo "Cannot create a GitHub release for $release_tag."
    exit 1
  fi

  # A freshly created release has no assets.
  : > "$assets_file"
else
  if ! read_release_assets "$release_json" > "$assets_file"; then
    echo "Cannot read the assets of the existing GitHub release ${release_tag}." >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 6. Release assets
# ---------------------------------------------------------------------------

echo "Uploading release files from $version_path..."

# Filenames are handled as glob results, so paths with spaces are supported and
# a pattern matching nothing is reported instead of being uploaded literally.
shopt -s nullglob

# We are picking up all relevant files lazily, using a substring.
# The first letter can be in either case, so we're skipping it.
release_files=("$version_path"/*odot*)
if [ "${#release_files[@]}" -eq 0 ]; then
  echo "ERROR: No release files matching '*odot*' were found in ${version_path}." >&2
  echo "       Make sure Godot has been built for ${release_tag}." >&2
  exit 1
fi
for f in "${release_files[@]}"; do
  upload_asset "$f"
done

# Do the same for .NET builds.
if [ -d "${version_path}/mono" ]; then
  mono_files=("${version_path}/mono"/*odot*)
  if [ "${#mono_files[@]}" -eq 0 ]; then
    echo "ERROR: No .NET release files matching '*odot*' were found in ${version_path}/mono." >&2
    exit 1
  fi
  for f in "${mono_files[@]}"; do
    upload_asset "$f"
  done
fi

# README.txt is only generated for pre-releases.
readme_path="$version_path/README.txt"
if [ "$godot_flavor" != "stable" ] && [ -f "${readme_path}" ]; then
  upload_asset "$readme_path"
fi

# SHA512-SUMS.txt is split into two: classic and mono, and we need to upload them as one.
# The copy truncates the destination, so the combined file is stable across runs.
checksums_path="$basedir/tmp/SHA512-SUMS.txt"
cp "$basedir/releases/$release_tag/SHA512-SUMS.txt" "$checksums_path"
if [ -d "${basedir}/releases/${release_tag}/mono" ]; then
  cat "$basedir/releases/$release_tag/mono/SHA512-SUMS.txt" >> "$checksums_path"
fi

upload_asset "$checksums_path"

echo "Release ${release_tag} is complete: ${uploaded_count} asset(s) uploaded, ${skipped_count} asset(s) already present."

echo "Done."
