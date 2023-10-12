### This script has been used to generate initial data for this repository
### and is preserved as a reference. DO NOT USE IT.

### Generate JSON metadata files for each official release of Godot.
###
### Files are put into a temporary folder tmp/releases. To generate
### the data we extract dates and commit hashes from releases published
### on TuxFamily. We also extract SHA512 checksums for release files
### where possible.


import os
import urllib.request
import urllib.error
import re
from datetime import datetime

url = 'https://downloads.tuxfamily.org/godotengine/'
skip_versions = [
    "2.1.1-fixup",
    "2.1.7-rc",
    "3.1.2-hotfix",
    "4.0-pre-alpha",
]
correct_dates = {
    "1.1": "2015-May-21 00:00:00",
    "2.0": "2016-Feb-23 00:00:00",
}
missing_hashes = {
    "2.1.6-rc1": "9ef833ec6d275e6271811f256acf23e29b2ccc33",
    "3.0.3-rc1": "63e70e3cd19d4ef42a293de40ffaf11aa735dad6",
    "3.0.3-rc2": "6635f2a1085a85f4195401d27d079a27bd98f3e0",
    "3.0.3-rc3": "f6406398670f41b55cd8e47bf5d8a1e764fb0c02",
    "3.1-alpha1": "2881a8e431308647fde21f9744b81269d0323922",
}

# Helpers.

def find_commit_hash(release_url):
    commit_hash = "";

    readme_url = f"{release_url}/README.txt"
    try:
        with urllib.request.urlopen(readme_url) as response:
            readme_text = response.read().decode()
            commit_pattern = re.compile(r'Built from commit ([a-f0-9]+)')
            commit_match = commit_pattern.search(readme_text)

            if commit_match:
                commit_hash = commit_match.group(1)
    except urllib.error.HTTPError:
        pass

    return commit_hash


def find_file_checksums(release_url):
    files = []

    checksums_url = f"{release_url}/SHA512-SUMS.txt"
    try:
        with urllib.request.urlopen(checksums_url) as response:
            checksums_text = response.read().decode()
            checksums_lines = checksums_text.splitlines()

            for line in checksums_lines:
                split_line = line.split("  ")
                files.append({
                    "filename": split_line[1],
                    "checksum": split_line[0]
                })

    except urllib.error.HTTPError:
        pass

    return files


def find_release_date(page_html):
    # <td class="n"><a href="Godot_v3.1-stable_export_templates.tpz">Godot_v3.1-stable_export_templates.tpz</a></td><td class="m">2019-Mar-13 13:23:30</td><td class="s">429.2M</td><td class="t">application/octet-stream</td>
    pattern = re.compile(r'<td class="n"><a href="(.+)_export_templates.tpz">(.+)_export_templates.tpz</a></td><td class="m">([A-Za-z0-9\-: ]+)</td><td class="s">([A-Z0-9\.]+)</td><td class="t">application/octet-stream</td>')
    matches = pattern.findall(page_html)

    if not matches:
        return None

    # 2016-Mar-07 20:33:34
    return datetime.strptime(matches[0][2], '%Y-%b-%d %H:%M:%S')


def generate_file(version_name, release_name, release_status, release_url):
    # Navigate to the release's sub-directory for parsing.
    with urllib.request.urlopen(release_url) as response:
        release_html = response.read().decode()

    # Get the release date.

    release_date = None
    if release_name in correct_dates:
        release_date = datetime.strptime(correct_dates[release_name], '%Y-%b-%d %H:%M:%S')
    else:
        # Extract the release date from the export templates file listed on the page.
        release_date = find_release_date(release_html)
    if not release_date:
        print(f"Skipped version '{release_name}' because it's not released")
        return release_html # Return raw HTML for further parsing.

    # Open the file for writing.

    output_path = f"./tmp/releases/godot-{release_name}.json"
    if release_status == "stable":
        output_path = f"./tmp/releases/godot-{release_name}-stable.json"

    with open(output_path, 'w') as f:
        # Get the commit hash / git reference.

        commit_hash = ""
        if release_status == "stable":
            commit_hash = f"{version_name}-stable"
        else:
            # Extract the commit hash for this release from the README.txt file.
            commit_hash = find_commit_hash(release_url);

            if not commit_hash and release_name in missing_hashes:
                commit_hash = missing_hashes[release_name]
            if not commit_hash:
                print(f"Version '{release_name}' has no commit hash!")

        # Start writing the file with basic meta information.

        f.write(
            f'{{\n'
            f'    "name": "{release_name}",\n'
            f'    "version": "{version_name}",\n'
            f'    "status": "{release_status}",\n'
            f'    "release_date": {int(release_date.timestamp())},\n'
            f'    "git_reference": "{commit_hash}",\n'
            f'\n'
            f'    "files": [\n'
        )

        # Generate the list of files.

        # Extract file names and checksums from SHA512-SUMS.txt.
        standard_files = find_file_checksums(release_url)
        mono_files = find_file_checksums(f"{release_url}/mono")

        for i, file in enumerate(standard_files):
            f.write(
                f'        {{\n'
                f'            "filename": "{file["filename"]}",\n'
                f'            "checksum": "{file["checksum"]}"\n'
                f'        }}{"" if i == len(standard_files) - 1 and len(mono_files) == 0 else ","}\n'
            )

        for i, file in enumerate(mono_files):
            f.write(
                f'        {{\n'
                f'            "filename": "{file["filename"]}",\n'
                f'            "checksum": "{file["checksum"]}"\n'
                f'        }}{"" if i == len(mono_files) - 1 else ","}\n'
            )

        # Finish the file.

        f.write(
            f'    ]\n'
            f'}}\n'
        )

        print(f"Written config '{output_path}'")

    return release_html # Return raw HTML for further parsing.


# Main routine.

# Request the download repository on TuxFamily.
with urllib.request.urlopen(url) as response:
    html = response.read().decode()

# Parse the directory index and find all the links that look like versions.
pattern = re.compile(r'<a href="(\d\.\d(\.\d(\.\d)?)?/)">')
matches = pattern.findall(html)

version_names = []
for match in matches:
    subfolder_name = match[0]
    if subfolder_name.endswith('/'):
        version_names.append(subfolder_name[:-1])

# Create the output directory if it doesn't exist.
if not os.path.exists("./tmp/releases"):
    os.makedirs("./tmp/releases")

for version_name in version_names:
    version_url = url + version_name

    # Generate a file for the stable release.

    version_html = generate_file(version_name, version_name, "stable", version_url)

    # Generate files for pre-releases of the stable release.

    # Look for potential builds.
    subfolder_pattern = re.compile(r'<a href="([^"]+/)">')
    subfolder_matches = subfolder_pattern.findall(version_html)

    folder_names = [match[:-1] for match in subfolder_matches if match not in ['mono/', '../']]
    for folder_name in folder_names:
        release_name = f"{version_name}-{folder_name}"
        if release_name in skip_versions:
            continue

        release_url = f"{version_url}/{folder_name}"
        generate_file(version_name, release_name, folder_name, release_url)
