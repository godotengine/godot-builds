import json
import os
import subprocess
import yaml
from datetime import datetime


website_versions = []


# Helpers.

def generate_notes(release_data):
    notes = ""

    version_version = release_data["version"]
    version_status = release_data["status"]
    version_tag = f"{version_version}-{version_status}"

    version_bits = version_version.split(".")
    version_flavor = "patch"
    if len(version_bits) == 2 and version_bits[1] == "0":
        version_flavor = "major"
    elif len(version_bits) == 2 and version_bits[1] != "0":
        version_flavor = "minor"

    # Add the intro line.

    version_name = version_version
    if version_status != "stable":
        version_name += " "
        if version_status.startswith("rc"):
            version_name += f"RC {version_status.removeprefix('rc')}"
        elif version_status.startswith("beta"):
            version_name += f"beta {version_status.removeprefix('beta')}"
        elif version_status.startswith("alpha"):
            version_name += f"alpha {version_status.removeprefix('alpha')}"
        elif version_status.startswith("dev"):
            version_name += f"dev {version_status.removeprefix('dev')}"
        else:
            version_name += version_status

    version_description = ""

    if version_status == "stable":
        version_bits = version_version.split(".")
        if version_flavor == "major":
            version_description = "a major release introducing new features and considerable changes to core systems. **Major version releases contain compatibility breaking changes.**"
        elif version_flavor == "minor":
            version_description = "a feature release improving upon the previous version in many aspects, such as usability and performance. Feature releases also contain new features, but preserve compatibility with previous releases."
        else:
            version_description = "a maintenance release addressing stability and usability issues, and fixing all sorts of bugs. Maintenance releases are compatible with previous releases and are recommended for adoption."
    else:
        flavor_name = "maintenance"
        if version_flavor == "major":
            flavor_name = "major"
        elif version_flavor == "minor":
            flavor_name = "feature"

        if version_status.startswith("rc"):
            version_description = f"a release candidate for the {version_version} {flavor_name} release. Release candidates focus on finalizing the release and fixing remaining critical bugs."
        elif version_status.startswith("beta"):
            version_description = f"a beta snapshot for the {version_version} {flavor_name} release. Beta snapshots are feature-complete and provided for public beta testing to catch as many bugs as possible ahead of the stable release."
        else: # alphas and devs go here.
            version_description = f"a dev snapshot for the {version_version} {flavor_name} release. Dev snapshots are in-development builds of the engine provided for early testing and feature evaluation while the engine is still being worked on."

    notes += f"**Godot {version_name}** is {version_description}\n\n"

    # Link to the bug tracker.

    notes += "Report bugs on GitHub after checking that they haven't been reported:\n"
    notes += "- https://github.com/godotengine/godot/issues\n"
    notes += "\n"

    # Add build information.

    # Only for pre-releases.
    if version_status != "stable":
        commit_hash = release_data["git_reference"]
        notes += f"Built from commit [{commit_hash}](https://github.com/godotengine/godot/commit/{commit_hash}).\n"
        notes += f"To make a custom build which would also be recognized as {version_status}, you should define `GODOT_VERSION_STATUS={version_status}` in your build environment prior to compiling.\n"
        notes += "\n"

    # Add useful links.

    notes += "----\n"
    notes += "\n"

    release_notes_url = ""
    release_notes_version = version_version
    if version_version == "3.2.4":
        release_notes_version = "3.3"

    for web_version in website_versions:
        if web_version["name"] != release_notes_version:
            continue
        if web_version["flavor"] == version_status:
            release_notes_url = f"https://godotengine.org{web_version['release_notes']}"
            break

        for web_release in web_version["releases"]:
            if web_release["name"] != version_status:
                continue
            release_notes_url = f"https://godotengine.org{web_release['release_notes']}"
            break

    notes += f"- [Release notes]({release_notes_url})\n"

    if version_status == "stable":
        notes += f"- [Complete changelog](https://godotengine.github.io/godot-interactive-changelog/#{version_version})\n"
        notes += f"- [Curated changelog](https://github.com/godotengine/godot/blob/{version_tag}/CHANGELOG.md)\n"
    else:
        notes += f"- [Complete changelog](https://godotengine.github.io/godot-interactive-changelog/#{version_tag})\n"

    notes += "- Download (GitHub): Expand **Assets** below\n"

    if version_status == "stable":
        notes += f"- [Download (TuxFamily)](https://downloads.tuxfamily.org/godotengine/{version_version})\n"
    else:
        notes += f"- [Download (TuxFamily)](https://downloads.tuxfamily.org/godotengine/{version_version}/{version_status})\n"

    notes += "\n"
    notes += "*All files for this release are mirrored under **Assets** below.*\n"

    return notes


with open("./temp/versions.yml", "r") as f:
    try:
        website_versions = yaml.safe_load(f)
    except yaml.YAMLError as exc:
        pass

releases = []

# Read JSON files and generate GitHub release in order.

releases_path = "./releases"

dir_contents = os.listdir(releases_path)
for filename in dir_contents:
    filepath = os.path.join(releases_path, filename)
    if not os.path.isfile(filepath):
        continue

    with open(filepath, 'r') as json_data:
        release_data = json.load(json_data)

    print(f"Reading release '{release_data['name']}' data.")
    releases.append({
        "file": filepath,
        "data": release_data
    })

# Sort by release date so we can create commits in order
releases.sort(key=lambda x: x['data']['release_date'])

# Generate a commit for each release, spoof the commit date to
# match the release date.

# Create the output directory if it doesn't exist.
if not os.path.exists("./temp/notes"):
    os.makedirs("./temp/notes")

for release_data in releases:
    release_tag = f"{release_data['data']['version']}-{release_data['data']['status']}"
    release_title = f"{release_data['data']['version']}-{release_data['data']['status']}"
    prerelease_flag = ""
    if release_data['data']['status'] != "stable":
        prerelease_flag = "--prerelease"

    release_notes = generate_notes(release_data['data'])
    release_notes_file = f"./temp/notes/release-notes-{release_tag}.txt"
    with open(release_notes_file, 'w') as temp_notes:
        temp_notes.write(release_notes)

    cmd_create_release = f"gh release create {release_tag} --verify-tag --title \"{release_title}\" --notes-file {release_notes_file} {prerelease_flag}"

    print(cmd_create_release)
    subprocess.run(cmd_create_release)
