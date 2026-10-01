#!/usr/bin/env bash
#
# Scenario tests for tools/upload-github.sh.
#
# The real script is executed against a throwaway environment:
#
#   - a git repository standing in for the godot-builds clone (with a bare
#     "origin" remote),
#   - a git repository standing in for the Godot source checkout,
#   - a godot-build-scripts-like tree with fake build artifacts,
#   - a stub `gh` executable (tools/tests/upload-github/stubs/gh).
#
# Nothing is downloaded from, pushed to, or published on GitHub.

set -uo pipefail

tests_dir=$(dirname "$(readlink -f "$0")")
repo_root=$(git -C "$tests_dir" rev-parse --show-toplevel)
# shellcheck source=../test-lib.sh
# shellcheck disable=SC1091 # test-lib.sh is sourced from a path computed at runtime.
source "${tests_dir}/../test-lib.sh"

# Deterministic glob expansion, sorting and messages.
export LC_ALL=C
export TZ=UTC

stub_source="${tests_dir}/stubs/gh"

# Remove the fixture of the last scenario on exit.
workdir=""
trap 'if [ -n "$workdir" ] && [ -d "$workdir" ]; then rm -rf "$workdir"; fi' EXIT

# Fixture state, set by setup_fixture().
workdir=""
tag=""
builds=""
scripts=""
remote=""
state=""
gh_log=""

# Result of the last run_upload() call.
run_exit=0
run_stdout=""
run_stderr=""
gh_log_marker=0

# ---------------------------------------------------------------------------
# Fixture
# ---------------------------------------------------------------------------

setup_fixture() {
  local version="$1"
  local flavor="$2"
  local suffix
  local index

  # Remove the fixture of the previous scenario.
  if [ -n "$workdir" ] && [ -d "$workdir" ]; then
    rm -rf "$workdir"
  fi

  tag="${version}-${flavor}"
  workdir=$(mktemp -d "${TMPDIR:-/tmp}/godot-builds-upload-test-XXXXXX")
  builds="$workdir/builds"
  scripts="$workdir/scripts"
  remote="$workdir/remote.git"
  state="$workdir/state"
  gh_log="$workdir/logs/gh-calls.log"

  mkdir -p "$workdir/logs" "$workdir/home"

  # Isolate git from the configuration of the machine running the tests.
  cat > "$workdir/home/.gitconfig" <<EOF
[user]
    name = Godot Builds Tests
    email = tests@example.com
[init]
    defaultBranch = main
[commit]
    gpgsign = false
[tag]
    gpgSign = false
EOF
  export HOME="$workdir/home"
  export GIT_CONFIG_NOSYSTEM=1

  # Repository standing in for the Godot source checkout.
  mkdir -p "$scripts/git"
  git init -q -b main "$scripts/git"
  echo "Godot source" > "$scripts/git/README.md"
  git -C "$scripts/git" add README.md
  git -C "$scripts/git" commit -q -m "Godot source"
  godot_commit=$(git -C "$scripts/git" rev-parse HEAD)

  # Repository standing in for the godot-builds clone.
  git init -q --bare -b main "$remote"
  git init -q -b main "$builds"
  mkdir -p "$builds/tools" "$builds/releases"
  cp "$repo_root/tools/upload-github.sh" \
    "$repo_root/tools/create-release-metadata.py" \
    "$repo_root/tools/create-release-notes.py" \
    "$builds/tools/"
  chmod +x "$builds/tools/upload-github.sh"
  git -C "$builds" remote add origin "$remote"
  git -C "$builds" add tools
  git -C "$builds" commit -q -m "Add release tooling"
  git -C "$builds" push -q origin main
  initial_commit=$(git -C "$builds" rev-parse HEAD)

  # Build artifacts, as godot-build-scripts would have produced them.
  local release_dir="$scripts/releases/$tag"
  mkdir -p "$release_dir/mono" "$scripts/tmp"

  classic_files=()
  for suffix in "extra build.zip" "linux.x86_64.zip" "macos.universal.zip" "web_editor.zip" "win64.exe.zip"; do
    classic_files+=("Godot_v${tag}_${suffix}")
    printf 'payload of %s\n' "$suffix" > "${release_dir}/Godot_v${tag}_${suffix}"
  done
  mono_files=("Godot_v${tag}_mono_win64.zip")
  printf 'mono payload\n' > "${release_dir}/mono/${mono_files[0]}"

  # Not a build artifact: only used by the pre-release check.
  printf 'pre-release readme\n' > "$release_dir/README.txt"

  # Checksums, in the "<sha512>  <filename>" format used by create-release-metadata.py.
  : > "$release_dir/SHA512-SUMS.txt"
  index=0
  for suffix in "extra build.zip" "linux.x86_64.zip" "macos.universal.zip" "web_editor.zip" "win64.exe.zip"; do
    printf '%0128d  Godot_v%s_%s\n' "$index" "$tag" "$suffix" >> "$release_dir/SHA512-SUMS.txt"
    index=$((index + 1))
  done
  printf '%0128d  %s\n' "$index" "${mono_files[0]}" > "$release_dir/mono/SHA512-SUMS.txt"

  # The stub GitHub CLI.
  mkdir -p "$workdir/stubs"
  cp "$stub_source" "$workdir/stubs/gh"
  chmod +x "$workdir/stubs/gh"
  export GH_STUB_STATE="$state"
  export GH_STUB_LOG="$gh_log"
  export GH_STUB_BUILDS_REPO="$builds"
  : > "$gh_log"

  unset GH_STUB_FAIL_UPLOAD GH_STUB_BROKEN_UPLOAD GH_STUB_RELEASE_API_ERROR \
    GH_STUB_REPO_API_ERROR GH_STUB_RELEASE_TAG GH_STUB_FAIL_RELEASE_CREATE
}

# Whether the emulated release exists.
release_exists() {
  stub _stub has-release "$tag" 2> /dev/null
}

# Runs tools/upload-github.sh in the fixture.
run_upload() {
  gh_log_marker=$(wc -l < "$gh_log" | tr -d '[:space:]')

  (
    cd "$scripts" || exit 1
    PATH="$workdir/stubs:$PATH" "$builds/tools/upload-github.sh" "$@"
  ) > "$workdir/logs/run.out" 2> "$workdir/logs/run.err"
  run_exit=$?

  run_stdout=$(cat "$workdir/logs/run.out")
  run_stderr=$(cat "$workdir/logs/run.err")
}

dump_run() {
  printf '       --- exit: %s\n' "$run_exit" >&2
  printf '       --- stdout:\n%s\n' "$run_stdout" >&2
  printf '       --- stderr:\n%s\n' "$run_stderr" >&2
}

# Calls made to the stub by the last run only.
last_run_calls() {
  tail -n +"$((gh_log_marker + 1))" "$gh_log"
}

call_count() {
  last_run_calls | grep -cF -- "$1"
}

stdout_line_count() {
  printf '%s\n' "$run_stdout" | grep -cE -- "$1"
}

metadata_path() {
  printf '%s/releases/godot-%s.json' "$builds" "$tag"
}

metadata_hash() {
  sha256sum "$(metadata_path)" | cut -d ' ' -f 1
}

commit_count() {
  git -C "$builds" rev-list --count HEAD
}

metadata_commit_count() {
  git -C "$builds" log --oneline -- "releases/godot-${tag}.json" | wc -l | tr -d '[:space:]'
}

local_tag_sha() {
  git -C "$builds" rev-parse -q --verify "refs/tags/${tag}" 2> /dev/null || true
}

remote_tag_sha() {
  git -C "$builds" ls-remote --tags --refs origin "refs/tags/${tag}" | awk 'NF > 0 { print $1 }'
}

local_main_sha() {
  git -C "$builds" rev-parse main
}

remote_main_sha() {
  git -C "$builds" ls-remote origin refs/heads/main | awk 'NF > 0 { print $1 }'
}

stub() {
  GH_STUB_STATE="$state" "$workdir/stubs/gh" "$@"
}

# Assets of the release, sorted, one per line.
assets_of() {
  stub _stub list-assets "$tag" | cut -f1 | LC_ALL=C sort
}

asset_count() {
  stub _stub list-assets "$tag" | grep -c . || true
}

# The complete set of assets expected for the fixture.
expected_assets() {
  local flavor="$1"
  local name

  for name in "${classic_files[@]}" "${mono_files[@]}"; do
    printf '%s\n' "$name"
  done
  if [ "$flavor" != "stable" ]; then
    printf 'README.txt\n'
  fi
  printf 'SHA512-SUMS.txt\n'
}

assert_assets_equal() {
  local flavor="$1"
  local message="$2"

  assert_equal "$(expected_assets "$flavor" | LC_ALL=C sort)" "$(assets_of)" "$message"
}

# Commits an unrelated file, to have another commit to point tags at.
add_unrelated_commit() {
  echo "$1" > "$builds/$1"
  git -C "$builds" add "$1"
  git -C "$builds" commit -q -m "Add $1"
  git -C "$builds" rev-parse HEAD
}

# Force-moves the tag on the bare remote, from a throwaway clone.
force_remote_tag() {
  local target="$1"
  local clone="$workdir/scratch-clone"

  rm -rf "$clone"
  git clone -q "$remote" "$clone"
  git -C "$clone" tag -f "$tag" "$target" > /dev/null
  git -C "$clone" push -q --force origin "refs/tags/${tag}"
  rm -rf "$clone"
}

delete_remote_tag() {
  local clone="$workdir/scratch-clone"

  rm -rf "$clone"
  git clone -q "$remote" "$clone"
  git -C "$clone" push -q origin ":refs/tags/${tag}"
  rm -rf "$clone"
}

# ---------------------------------------------------------------------------
# Test A: first run of a pre-release
# ---------------------------------------------------------------------------
# Test P: resuming with a source checkout which moved to another commit
# ---------------------------------------------------------------------------

scenario_checkout_moved() {
  describe "Test P: a moved Godot checkout is detected before anything is uploaded"

  setup_fixture 4.8 dev7
  run_upload -v 4.8 -f dev7 -r test/godot-builds
  assert_equal "0" "$run_exit" "preparation run succeeds"

  local assets_before
  assets_before=$(assets_of)

  # The Godot checkout moved on, e.g. because a newer snapshot was fetched.
  echo "newer source" > "$scripts/git/newer.txt"
  git -C "$scripts/git" add newer.txt
  git -C "$scripts/git" commit -q -m "Move on"
  local moved_commit
  moved_commit=$(git -C "$scripts/git" rev-parse HEAD)

  run_upload -v 4.8 -f dev7 -r test/godot-builds

  assert_not_equal "0" "$run_exit" "the run fails"
  assert_contains "$run_stderr" "Release metadata mismatch in the working tree" "the failure reports the metadata mismatch"
  assert_contains "$run_stderr" "expected: name '4.8-dev7', git reference '${moved_commit}'" "the failure reports the expected identity"
  assert_contains "$run_stderr" "found:    name '4.8-dev7', git reference '${godot_commit}'" "the failure reports the recorded identity"
  assert_equal "0" "$(call_count "release create ${tag}")" "no release was created"
  assert_equal "0" "$(call_count "release upload ${tag}")" "no asset was uploaded"
  assert_equal "$assets_before" "$(assets_of)" "the release is unchanged"
}

# ---------------------------------------------------------------------------
# Test Q: a failed release creation can be resumed
# ---------------------------------------------------------------------------

scenario_release_creation_failed() {
  describe "Test Q: a failed release creation can be resumed"

  setup_fixture 4.8 dev7
  export GH_STUB_FAIL_RELEASE_CREATE=1

  run_upload -v 4.8 -f dev7 -r test/godot-builds

  assert_not_equal "0" "$run_exit" "the first run fails"
  assert_contains "$run_stdout" "Cannot create a GitHub release for ${tag}" "the failure reports the release creation"
  assert_equal "0" "$(call_count "release upload ${tag}")" "no asset was uploaded"

  if release_exists; then
    check_fail "no release was created" "the emulated release exists"
  else
    check_pass "no release was created"
  fi

  unset GH_STUB_FAIL_RELEASE_CREATE
  run_upload -v 4.8 -f dev7 -r test/godot-builds

  if [ "$run_exit" != "0" ]; then
    check_fail "the second run exits successfully" "exited with $run_exit"
    dump_run
    return
  fi
  check_pass "the second run exits successfully"

  assert_equal "1" "$(metadata_commit_count)" "no duplicate metadata commit was created"
  assert_equal "1" "$(call_count "release create ${tag}")" "the release was created once"
  assert_equal "8" "$(call_count "release upload ${tag}")" "all eight assets were uploaded"
  assert_assets_equal dev7 "the release holds every expected asset"
}

# ---------------------------------------------------------------------------

scenario_first_run() {
  describe "Test A: first run publishes metadata, tag, release and assets"

  setup_fixture 4.8 dev7
  run_upload -v 4.8 -f dev7 -r test/godot-builds

  if [ "$run_exit" != "0" ]; then
    check_fail "first run exits successfully" "exited with $run_exit"
    dump_run
    return
  fi
  check_pass "first run exits successfully"

  assert_file_exists "$(metadata_path)" "release metadata was created"

  local metadata
  metadata=$(cat "$(metadata_path)")
  assert_contains "$metadata" "\"name\": \"4.8-dev7\"" "metadata records the release name"
  assert_contains "$metadata" "\"git_reference\": \"${godot_commit}\"" "metadata records the built commit"

  assert_equal "1" "$(metadata_commit_count)" "release metadata was committed exactly once"
  assert_equal "2" "$(commit_count)" "exactly one commit was added to main"
  assert_equal "$(local_main_sha)" "$(remote_main_sha)" "main was pushed to origin"

  local tag_commit
  tag_commit=$(git -C "$builds" rev-parse "refs/tags/${tag}^{commit}")
  assert_equal "$(local_main_sha)" "$tag_commit" "tag points at the metadata commit"
  assert_equal "$tag_commit" "$(remote_tag_sha)" "tag was pushed to origin"

  assert_equal "1" "$(call_count "release create ${tag}")" "exactly one GitHub release was created"
  assert_contains "$(last_run_calls)" "release create ${tag} --prerelease" "release was created as a pre-release"
  assert_not_contains "$(last_run_calls)" "release create ${tag} --prerelease --draft" "release was not created as a draft"

  assert_equal "8" "$(call_count "release upload ${tag}")" "all eight assets were uploaded"
  assert_equal "0" "$(stdout_line_count '^Skipping ')" "no asset was skipped"
  assert_contains "$run_stdout" "Uploading Godot_v4.8-dev7_extra build.zip..." "asset with a space in its name was uploaded"
  assert_contains "$run_stdout" "Uploading SHA512-SUMS.txt..." "checksum file was uploaded"

  assert_assets_equal dev7 "all expected assets are part of the release"
  assert_equal "8" "$(asset_count)" "the release holds exactly eight assets"
}

# ---------------------------------------------------------------------------
# Test B: resume after an interrupted upload (plus Test C: complete release)
# ---------------------------------------------------------------------------

scenario_resume_after_failed_upload() {
  describe "Test B: interrupted upload can be resumed by re-running"

  setup_fixture 4.8 dev7
  export GH_STUB_FAIL_UPLOAD="Godot_v4.8-dev7_macos.universal.zip"

  run_upload -v 4.8 -f dev7 -r test/godot-builds

  assert_not_equal "0" "$run_exit" "first run fails when an upload fails"
  assert_contains "$run_stderr" "Re-run the same command" "the failure tells the maintainer to re-run"

  # State left behind by the failed run.
  assert_equal "1" "$(metadata_commit_count)" "metadata was committed before the failure"
  assert_equal "2" "$(commit_count)" "no extra commit was created"
  assert_equal "$(local_main_sha)" "$(remote_main_sha)" "main was pushed before the failure"
  assert_equal "1" "$(call_count "release create ${tag}")" "the release was created once"
  assert_equal "3" "$(call_count "release upload ${tag}")" "three uploads were attempted (two succeeded, one failed)"

  local failed_assets
  failed_assets=$(assets_of)
  assert_equal "Godot_v4.8-dev7_extra build.zip
Godot_v4.8-dev7_linux.x86_64.zip" "$failed_assets" "only the assets uploaded before the failure are published"
  assert_not_contains "$failed_assets" "Godot_v4.8-dev7_web_editor.zip" "later assets were not attempted"
  assert_not_contains "$failed_assets" "Godot_v4.8-dev7_mono_win64.zip" ".NET assets were not attempted"
  assert_not_contains "$failed_assets" "SHA512-SUMS.txt" "checksum file was not uploaded"

  # Record the state which must not change.
  local metadata_before commits_before tag_before remote_tag_before remote_main_before
  metadata_before=$(metadata_hash)
  commits_before=$(commit_count)
  tag_before=$(local_tag_sha)
  remote_tag_before=$(remote_tag_sha)
  remote_main_before=$(remote_main_sha)

  unset GH_STUB_FAIL_UPLOAD
  run_upload -v 4.8 -f dev7 -r test/godot-builds

  if [ "$run_exit" != "0" ]; then
    check_fail "second run exits successfully" "exited with $run_exit"
    dump_run
    return
  fi
  check_pass "second run exits successfully"

  assert_equal "$metadata_before" "$(metadata_hash)" "release metadata was not modified (byte identical)"
  assert_equal "$commits_before" "$(commit_count)" "no commit was added by the second run"
  assert_equal "1" "$(metadata_commit_count)" "no duplicate metadata commit was created"
  assert_equal "$tag_before" "$(local_tag_sha)" "the local tag was not moved"
  assert_equal "$remote_tag_before" "$(remote_tag_sha)" "the remote tag was not moved"
  assert_equal "$remote_main_before" "$(remote_main_sha)" "main was not re-pushed"

  assert_equal "0" "$(call_count "release create ${tag}")" "no second GitHub release was created"
  assert_equal "1" "$(call_count "api repos/test/godot-builds")" "the repository was probed once for reachability"
  assert_equal "1" "$(call_count "api releases/tags/${tag}")" "the existing release was looked up once"

  assert_equal "6" "$(call_count "release upload ${tag}")" "only the six missing assets were uploaded"
  assert_contains "$run_stdout" "Skipping Godot_v4.8-dev7_extra build.zip: already uploaded" "the first asset was skipped"
  assert_contains "$run_stdout" "Skipping Godot_v4.8-dev7_linux.x86_64.zip: already uploaded" "the second asset was skipped"
  assert_not_contains "$run_stdout" "Skipping Godot_v4.8-dev7_macos.universal.zip" "the failed asset was not skipped"
  assert_contains "$run_stdout" "Uploading Godot_v4.8-dev7_macos.universal.zip..." "the failed asset was uploaded"
  assert_contains "$run_stdout" "Uploading Godot_v4.8-dev7_web_editor.zip..." "the never attempted asset was uploaded"
  assert_contains "$run_stdout" "Uploading Godot_v4.8-dev7_mono_win64.zip..." "the .NET asset was uploaded"
  assert_contains "$run_stdout" "Uploading README.txt..." "the pre-release readme was uploaded"
  assert_contains "$run_stdout" "Uploading SHA512-SUMS.txt..." "the checksum file was uploaded"

  assert_assets_equal dev7 "the resumed release holds every expected asset"
  assert_equal "8" "$(asset_count)" "no asset was duplicated by the resume"

  # Test C: nothing is left to do.
  describe "Test C: re-running a complete release uploads nothing"

  metadata_before=$(metadata_hash)
  commits_before=$(commit_count)
  run_upload -v 4.8 -f dev7 -r test/godot-builds

  if [ "$run_exit" != "0" ]; then
    check_fail "third run exits successfully" "exited with $run_exit"
    dump_run
    return
  fi
  check_pass "third run exits successfully"

  assert_equal "0" "$(call_count "release upload ${tag}")" "no asset was uploaded again"
  assert_equal "0" "$(call_count "release create ${tag}")" "no release was created"
  assert_equal "8" "$(stdout_line_count '^Skipping ')" "all eight assets were reported as skipped"
  assert_assets_equal dev7 "the release is unchanged"
  assert_equal "8" "$(asset_count)" "the release still holds eight assets"
  assert_equal "$metadata_before" "$(metadata_hash)" "the metadata is untouched"
  assert_equal "$commits_before" "$(commit_count)" "no commit was added"
}

# ---------------------------------------------------------------------------
# Test D: existing tag pointing at the wrong commit
# ---------------------------------------------------------------------------

scenario_wrong_tag_target() {
  describe "Test D: a tag pointing at the wrong commit is refused"

  setup_fixture 4.8 dev7
  run_upload -v 4.8 -f dev7 -r test/godot-builds
  assert_equal "0" "$run_exit" "preparation run succeeds"

  # Point the tag, locally and on the remote, at the initial commit, which has
  # no release metadata for this release.
  git -C "$builds" tag -f "$tag" "$initial_commit" > /dev/null
  force_remote_tag "$initial_commit"

  local remote_tag_before local_tag_before
  remote_tag_before=$(remote_tag_sha)
  local_tag_before=$(local_tag_sha)

  run_upload -v 4.8 -f dev7 -r test/godot-builds

  assert_not_equal "0" "$run_exit" "the run fails"
  assert_contains "$run_stderr" "does not contain releases/godot-${tag}.json" "the failure explains the tag mismatch"
  assert_equal "$local_tag_before" "$(local_tag_sha)" "the local tag was not moved"
  assert_equal "$remote_tag_before" "$(remote_tag_sha)" "the remote tag was not moved"
  assert_equal "0" "$(call_count "release create ${tag}")" "no release was created"
  assert_equal "0" "$(call_count "release upload ${tag}")" "no asset was uploaded"
  assert_assets_equal dev7 "the release is unchanged"
}

# ---------------------------------------------------------------------------
# Test E: local and remote tags diverging
# ---------------------------------------------------------------------------

scenario_tag_divergence() {
  describe "Test E: diverging local and remote tags are refused"

  setup_fixture 4.8 dev7
  run_upload -v 4.8 -f dev7 -r test/godot-builds
  assert_equal "0" "$run_exit" "preparation run succeeds"

  local other_commit
  other_commit=$(add_unrelated_commit unrelated.txt)

  # Local tag on the new commit, remote tag on the initial one.
  git -C "$builds" tag -f "$tag" "$other_commit" > /dev/null
  force_remote_tag "$initial_commit"

  local local_before remote_before
  local_before=$(local_tag_sha)
  remote_before=$(remote_tag_sha)

  run_upload -v 4.8 -f dev7 -r test/godot-builds

  assert_not_equal "0" "$run_exit" "the run fails"
  assert_contains "$run_stderr" "points at ${local_before} locally" "the failure reports the local tag"
  assert_contains "$run_stderr" "${remote_before} on 'origin'" "the failure reports the remote tag"
  assert_contains "$run_stderr" "Refusing to move or overwrite it" "the failure refuses to force-move the tag"
  assert_equal "$local_before" "$(local_tag_sha)" "the local tag was not moved"
  assert_equal "$remote_before" "$(remote_tag_sha)" "the remote tag was not moved"
  assert_equal "0" "$(call_count "release create ${tag}")" "no release was created"
  assert_equal "0" "$(call_count "release upload ${tag}")" "no asset was uploaded"
}

# ---------------------------------------------------------------------------
# Test F: release exists but the tag does not
# ---------------------------------------------------------------------------

scenario_release_without_tag() {
  describe "Test F: a release whose tag is missing is refused"

  setup_fixture 4.8 dev7
  run_upload -v 4.8 -f dev7 -r test/godot-builds
  assert_equal "0" "$run_exit" "preparation run succeeds"

  git -C "$builds" tag -d "$tag" > /dev/null
  delete_remote_tag

  run_upload -v 4.8 -f dev7 -r test/godot-builds

  assert_not_equal "0" "$run_exit" "the run fails"
  assert_contains "$run_stderr" "A GitHub release exists for ${tag}, but the tag ${tag} is" "the failure explains the inconsistency"
  assert_equal "" "$(local_tag_sha)" "no local tag was created"
  assert_equal "" "$(remote_tag_sha)" "no tag was pushed"
  assert_equal "0" "$(call_count "release create ${tag}")" "no release was created"
  assert_equal "0" "$(call_count "release upload ${tag}")" "no asset was uploaded"
  assert_assets_equal dev7 "the release is unchanged"
}

# ---------------------------------------------------------------------------
# Test G: release attached to another tag
# ---------------------------------------------------------------------------

scenario_release_tag_mismatch() {
  describe "Test G: a release attached to another tag is refused"

  setup_fixture 4.8 dev7
  run_upload -v 4.8 -f dev7 -r test/godot-builds
  assert_equal "0" "$run_exit" "preparation run succeeds"

  # Replace the emulated release with one attached to a different tag.
  GH_STUB_RELEASE_TAG="4.8-dev6" stub _stub create-release "$tag" false true

  run_upload -v 4.8 -f dev7 -r test/godot-builds

  assert_not_equal "0" "$run_exit" "the run fails"
  assert_contains "$run_stderr" "is attached to tag '4.8-dev6'" "the failure reports the unexpected tag"
  assert_equal "0" "$(call_count "release create ${tag}")" "no release was created"
  assert_equal "0" "$(call_count "release upload ${tag}")" "no asset was uploaded"
}

# ---------------------------------------------------------------------------
# Test H: release created but not populated yet
# ---------------------------------------------------------------------------

scenario_release_without_assets() {
  describe "Test H: a release created without assets is populated on re-run"

  setup_fixture 4.8 dev7
  run_upload -v 4.8 -f dev7 -r test/godot-builds
  assert_equal "0" "$run_exit" "preparation run succeeds"

  # Simulate a release which was created but never received a single asset.
  stub _stub create-release "$tag" false true
  assert_equal "0" "$(asset_count)" "the release has no assets"

  run_upload -v 4.8 -f dev7 -r test/godot-builds

  if [ "$run_exit" != "0" ]; then
    check_fail "the run exits successfully" "exited with $run_exit"
    dump_run
    return
  fi
  check_pass "the run exits successfully"

  assert_equal "0" "$(call_count "release create ${tag}")" "no second release was created"
  assert_equal "8" "$(call_count "release upload ${tag}")" "all eight assets were uploaded"
  assert_assets_equal dev7 "the release now holds every expected asset"
}

# ---------------------------------------------------------------------------
# Test I: GitHub API failures are not mistaken for a missing release
# ---------------------------------------------------------------------------

scenario_api_failures() {
  describe "Test I: GitHub API failures are reported instead of guessed around"

  setup_fixture 4.8 dev7
  export GH_STUB_REPO_API_ERROR=1
  run_upload -v 4.8 -f dev7 -r test/godot-builds

  assert_not_equal "0" "$run_exit" "an unreachable repository fails the run"
  assert_contains "$run_stderr" "Cannot access repository test/godot-builds" "the failure reports the repository problem"
  assert_contains "$run_stderr" "Refusing to continue" "the failure refuses to continue blind"
  assert_equal "0" "$(call_count "release create ${tag}")" "no release was created"
  assert_equal "0" "$(call_count "release upload ${tag}")" "no asset was uploaded"

  setup_fixture 4.8 dev7
  unset GH_STUB_REPO_API_ERROR
  export GH_STUB_RELEASE_API_ERROR=1
  run_upload -v 4.8 -f dev7 -r test/godot-builds

  assert_not_equal "0" "$run_exit" "a failing release lookup fails the run"
  assert_contains "$run_stderr" "Failed to look up the GitHub release ${tag}" "the failure reports the release lookup problem"
  assert_contains "$run_stderr" "Refusing to continue" "the failure refuses to continue blind"
  assert_equal "0" "$(call_count "release create ${tag}")" "no release was created"
  assert_equal "0" "$(call_count "release upload ${tag}")" "no asset was uploaded"
}

# ---------------------------------------------------------------------------
# Test J: a partially uploaded asset is not silently accepted
# ---------------------------------------------------------------------------

scenario_broken_asset() {
  describe "Test J: an asset with an unexpected size is not silently skipped"

  setup_fixture 4.8 dev7
  export GH_STUB_BROKEN_UPLOAD="Godot_v4.8-dev7_macos.universal.zip"

  run_upload -v 4.8 -f dev7 -r test/godot-builds
  assert_not_equal "0" "$run_exit" "the interrupted upload fails the run"

  local broken_size
  broken_size=$(stub _stub list-assets "$tag" | awk -F'\t' '$1 == "Godot_v4.8-dev7_macos.universal.zip" { print $2 }')
  assert_not_equal "" "$broken_size" "the interrupted upload left a partial asset behind"

  unset GH_STUB_BROKEN_UPLOAD
  run_upload -v 4.8 -f dev7 -r test/godot-builds

  assert_not_equal "0" "$run_exit" "the re-run fails instead of skipping the partial asset"
  assert_contains "$run_stderr" "differs from the local file" "the failure reports the size difference"
  assert_contains "$run_stderr" "gh release delete-asset ${tag}" "the failure suggests how to remove the asset"
  assert_equal "0" "$(call_count "release upload ${tag}")" "no asset was uploaded"
  assert_equal "$broken_size" "$(stub _stub list-assets "$tag" | awk -F'\t' '$1 == "Godot_v4.8-dev7_macos.universal.zip" { print $2 }')" "the partial asset was left untouched"
}

# ---------------------------------------------------------------------------
# Test K: pre-release readme, stable release and draft handling
# ---------------------------------------------------------------------------

scenario_readme_and_flavors() {
  describe "Test K: pre-release readme, stable flavour and drafts"

  setup_fixture 4.8 dev7
  run_upload -v 4.8 -f dev7 -r test/godot-builds
  assert_equal "0" "$run_exit" "pre-release run succeeds"
  assert_contains "$(assets_of)" "README.txt" "the pre-release readme was uploaded"

  run_upload -v 4.8 -f dev7 -r test/godot-builds
  assert_equal "0" "$run_exit" "pre-release re-run succeeds"
  assert_contains "$run_stdout" "Skipping README.txt: already uploaded" "the readme is skipped on re-run"

  setup_fixture 4.8 stable
  run_upload -v 4.8 -f stable -d -r test/godot-builds

  if [ "$run_exit" != "0" ]; then
    check_fail "stable run exits successfully" "exited with $run_exit"
    dump_run
    return
  fi
  check_pass "stable run exits successfully"

  assert_not_contains "$(assets_of)" "README.txt" "no readme is uploaded for a stable release"
  assert_contains "$(last_run_calls)" "release create ${tag} --draft" "the stable release was created as a draft"
  assert_not_contains "$(last_run_calls)" "--prerelease" "the stable release is not a pre-release"
  assert_assets_equal stable "the stable release holds every expected asset"
  assert_equal "7" "$(asset_count)" "the stable release holds seven assets"

  local metadata
  metadata=$(cat "$(metadata_path)")
  assert_contains "$metadata" "\"name\": \"4.8\"" "the stable metadata uses the version as name"
  assert_contains "$metadata" "\"git_reference\": \"4.8-stable\"" "the stable metadata records the release tag"
}

# ---------------------------------------------------------------------------
# Test L: checksum file generation
# ---------------------------------------------------------------------------

scenario_checksums() {
  describe "Test L: the combined checksum file is stable across runs"

  setup_fixture 4.8 dev7
  run_upload -v 4.8 -f dev7 -r test/godot-builds
  assert_equal "0" "$run_exit" "first run succeeds"

  local combined expected_combined
  combined=$(cat "$scripts/tmp/SHA512-SUMS.txt")
  expected_combined=$(cat "$scripts/releases/$tag/SHA512-SUMS.txt"; cat "$scripts/releases/$tag/mono/SHA512-SUMS.txt")
  assert_equal "$expected_combined" "$combined" "the checksum file combines the classic and .NET checksums"
  assert_contains "$(assets_of)" "SHA512-SUMS.txt" "the checksum file was uploaded"

  run_upload -v 4.8 -f dev7 -r test/godot-builds
  assert_equal "0" "$run_exit" "second run succeeds"
  assert_equal "$expected_combined" "$(cat "$scripts/tmp/SHA512-SUMS.txt")" "the checksum file is not appended to twice"
  assert_contains "$run_stdout" "Skipping SHA512-SUMS.txt: already uploaded" "the checksum file is skipped on re-run"
  assert_equal "8" "$(asset_count)" "the release still holds eight assets"
}

# ---------------------------------------------------------------------------
# Test M: metadata generated but not committed yet
# ---------------------------------------------------------------------------

scenario_uncommitted_metadata() {
  describe "Test M: metadata left uncommitted by an interrupted run is reused"

  setup_fixture 4.8 dev7

  # Generate the metadata the way an interrupted first run would have.
  (
    cd "$scripts" || exit 1
    basedir="$scripts" buildsdir="$builds" "$builds/tools/create-release-metadata.py" -v 4.8 -f dev7 -g "$godot_commit"
  ) > /dev/null

  assert_file_exists "$(metadata_path)" "the metadata was generated"
  assert_equal "0" "$(metadata_commit_count)" "the metadata is not committed yet"

  local metadata_before
  metadata_before=$(metadata_hash)

  run_upload -v 4.8 -f dev7 -r test/godot-builds

  if [ "$run_exit" != "0" ]; then
    check_fail "the run exits successfully" "exited with $run_exit"
    dump_run
    return
  fi
  check_pass "the run exits successfully"

  assert_equal "$metadata_before" "$(metadata_hash)" "the existing metadata was reused instead of regenerated"
  assert_equal "1" "$(metadata_commit_count)" "the metadata was committed exactly once"
  assert_equal "1" "$(call_count "release create ${tag}")" "one release was created"
  assert_equal "8" "$(call_count "release upload ${tag}")" "all eight assets were uploaded"
  assert_assets_equal dev7 "the release holds every expected asset"
}

# ---------------------------------------------------------------------------
# Test N: resuming from a checkout which only knows the remote tag
# ---------------------------------------------------------------------------

scenario_resume_from_remote_tag() {
  describe "Test N: re-running without the local tag fetches it from origin"

  setup_fixture 4.8 dev7
  run_upload -v 4.8 -f dev7 -r test/godot-builds
  assert_equal "0" "$run_exit" "preparation run succeeds"

  git -C "$builds" tag -d "$tag" > /dev/null
  assert_equal "" "$(local_tag_sha)" "the local tag is gone"

  local commits_before
  commits_before=$(commit_count)

  run_upload -v 4.8 -f dev7 -r test/godot-builds

  if [ "$run_exit" != "0" ]; then
    check_fail "the run exits successfully" "exited with $run_exit"
    dump_run
    return
  fi
  check_pass "the run exits successfully"

  assert_equal "$(local_main_sha)" "$(local_tag_sha)" "the tag was fetched instead of recreated"
  assert_equal "0" "$(call_count "release create ${tag}")" "no release was created"
  assert_equal "0" "$(call_count "release upload ${tag}")" "no asset was uploaded"
  assert_equal "8" "$(stdout_line_count '^Skipping ')" "all eight assets were reported as skipped"
  assert_equal "$commits_before" "$(commit_count)" "no commit was added"
  assert_assets_equal dev7 "the release is unchanged"
}

# ---------------------------------------------------------------------------
# Test O: the tag of a release is never overwritten by a second publication
# ---------------------------------------------------------------------------

scenario_no_retag() {
  describe "Test O: a completed release is not retagged nor re-created"

  setup_fixture 4.8 dev7
  run_upload -v 4.8 -f dev7 -r test/godot-builds
  assert_equal "0" "$run_exit" "preparation run succeeds"

  # A new commit lands on main after the release was published.
  local later_commit
  later_commit=$(add_unrelated_commit later.txt)

  run_upload -v 4.8 -f dev7 -r test/godot-builds
  assert_equal "0" "$run_exit" "the re-run succeeds"

  assert_not_equal "$later_commit" "$(local_tag_sha)" "the tag was not moved to the new commit"
  assert_equal "$(git -C "$builds" rev-parse "${later_commit}~1")" "$(git -C "$builds" rev-parse "refs/tags/${tag}^{commit}")" "the tag still points at the release commit"
  assert_equal "0" "$(call_count "release create ${tag}")" "no release was created"
  assert_equal "0" "$(call_count "release upload ${tag}")" "no asset was uploaded"
}

# ---------------------------------------------------------------------------

scenario_first_run
scenario_resume_after_failed_upload
scenario_wrong_tag_target
scenario_tag_divergence
scenario_release_without_tag
scenario_release_tag_mismatch
scenario_release_without_assets
scenario_api_failures
scenario_broken_asset
scenario_readme_and_flavors
scenario_checksums
scenario_uncommitted_metadata
scenario_resume_from_remote_tag
scenario_no_retag
scenario_checkout_moved
scenario_release_creation_failed

finish_tests
