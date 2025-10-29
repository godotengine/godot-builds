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

# Folder this script is called from, a.k.a its working directory.
export basedir=$(pwd)

# Folder where this scripts resides in.
scriptpath=$(readlink -f "$0")
scriptdir=$(dirname "$scriptpath")
# Root folder of this project, hopefully.
export buildsdir=$(dirname "$scriptdir")

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

cd git
git_reference=$(git rev-parse HEAD)
cd ..

# Generate release metadata and commit it to Git.

echo "Creating and committing release metadata for $release_tag..."

if ! $buildsdir/tools/create-release-metadata.py -v $godot_version -f $godot_flavor -g $git_reference; then
  echo "Failed to create release metadata for $release_tag."
  exit 1
fi

cd $buildsdir
git add ./releases/godot-$release_tag.json
git commit -m "Add Godot $release_tag"
git tag $release_tag
if ! git push --atomic origin main $release_tag; then
  echo "Failed to push release metadata for $release_tag to GitHub."
  exit 1
fi
cd $basedir

# Exactly one time it failed to create release immediately after pushing the tag,
# so we use this for protection...
sleep 2

# Generate GitHub release.

echo "Creating and publishing GitHub release for $release_tag..."

if ! $buildsdir/tools/create-release-notes.py -v $godot_version -f $godot_flavor -g $git_reference; then
  echo "Failed to create release notes for $release_tag."
  exit 1
fi

release_notes="$basedir/tmp/release-notes-$release_tag.txt"
release_flag=""
if [ $godot_flavor != "stable" ]; then
  release_flag="--prerelease"
fi
if [ $draft == "1" ]; then
  release_flag+=" --draft"
fi

if ! gh release create $release_tag --verify-tag --title "$release_tag" --notes-file $release_notes $release_flag -R $godot_repository; then
  echo "Cannot create a GitHub release for $release_tag."
  exit 1
fi

# Upload release files to GitHub.

echo "Uploading release files from $version_path..."

# We are picking up all relevant files lazily, using a substring.
# The first letter can be in either case, so we're skipping it.
for f in $version_path/*odot*; do
  echo "Uploading $f..."
  gh release upload $release_tag $f -R $godot_repository
done

# Do the same for .NET builds.
for f in $version_path/mono/*odot*; do
  echo "Uploading $f..."
  gh release upload $release_tag $f -R $godot_repository
done

# README.txt is only generated for pre-releases.
readme_path="$version_path/README.txt"
if [ $godot_flavor != "stable" ] && [ -f "${readme_path}" ]; then
  echo "Uploading $readme_path..."
  gh release upload $release_tag $readme_path -R $godot_repository
fi

# SHA512-SUMS.txt is split into two: classic and mono, and we need to upload them as one.
checksums_path="$basedir/tmp/SHA512-SUMS.txt"
cp $basedir/releases/$release_tag/SHA512-SUMS.txt $checksums_path
if [ -d "${basedir}/releases/${release_tag}/mono" ]; then
  cat $basedir/releases/$release_tag/mono/SHA512-SUMS.txt >> $checksums_path
fi

echo "Uploading $checksums_path..."
gh release upload $release_tag $checksums_path -R $godot_repository

echo "Done."
