#!/usr/bin/env python3
"""Vendor the latest stable github-markdown-css release."""

import argparse
import hashlib
import json
import os
import re
import tempfile
from pathlib import Path
from urllib.request import Request, urlopen


OWNER = "sindresorhus"
REPOSITORY = "github-markdown-css"
SEMVER = re.compile(r"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
COMMIT = re.compile(r"^[0-9a-f]{40}$")
NOTICE_PATH = re.compile(
    r"^THIRD_PARTY_NOTICES/github-markdown-css-"
    r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-license$"
)


def sha256(contents):
    return hashlib.sha256(contents).hexdigest()


def immutable_url(commit, name):
    return f"https://raw.githubusercontent.com/{OWNER}/{REPOSITORY}/{commit}/{name}"


def version_tuple(version):
    match = SEMVER.fullmatch(f"v{version}")
    if not match:
        raise ValueError(f"invalid semantic version: {version!r}")
    return tuple(int(part) for part in match.groups())


def remove_redundant_eof_blank_line(css):
    """Remove exactly the empty final line used by upstream."""
    return css[:-1] if css.endswith(b"\n\n") else css


def http_get(url):
    if not url.startswith("https://"):
        raise ValueError(f"refusing non-HTTPS URL: {url}")
    request = Request(url, headers={"Accept": "application/vnd.github+json", "User-Agent": "markdown-docker-css-updater"})
    with urlopen(request, timeout=30) as response:  # nosec B310: HTTPS is checked above
        if not response.geturl().startswith("https://"):
            raise ValueError(f"refusing redirect to non-HTTPS URL: {response.geturl()}")
        return response.read()


def json_get(fetch, url):
    return json.loads(fetch(url).decode("utf-8"))


def latest_release(fetch, api_base):
    release = json_get(fetch, f"{api_base}/repos/{OWNER}/{REPOSITORY}/releases/latest")
    tag = release.get("tag_name", "")
    if release.get("prerelease") or release.get("draft") or not SEMVER.fullmatch(tag):
        raise ValueError(f"latest release has invalid stable semantic tag: {tag!r}")
    return tag


def resolve_commit(fetch, api_base, tag):
    reference = json_get(fetch, f"{api_base}/repos/{OWNER}/{REPOSITORY}/git/ref/tags/{tag}")
    target = reference.get("object", {})
    for _ in range(5):
        if target.get("type") != "tag":
            break
        tag_object = target.get("sha", "")
        if not COMMIT.fullmatch(tag_object):
            raise ValueError("annotated tag object has invalid SHA")
        target = json_get(fetch, f"{api_base}/repos/{OWNER}/{REPOSITORY}/git/tags/{tag_object}").get("object", {})
    else:
        raise ValueError("annotated tag chain is too deep")
    commit = target.get("sha", "")
    if target.get("type") != "commit" or not COMMIT.fullmatch(commit):
        raise ValueError("tag does not resolve to a 40-character commit")
    return commit


def parse_manifest(path):
    rows = path.read_text(encoding="utf-8").splitlines()
    matches = []
    for index, row in enumerate(rows):
        columns = row.split("\t")
        if len(columns) == 5 and columns[4].startswith("github-markdown-css "):
            matches.append((index, columns))
    if len(matches) != 1:
        raise ValueError("expected exactly one github-markdown-css notice manifest row")
    return rows, matches[0]


def atomic_replace_all(writes):
    temporary_files = []
    try:
        for path, contents in writes.items():
            if path.is_symlink():
                raise ValueError(f"refusing symlinked destination: {path}")
            mode = path.stat().st_mode & 0o777 if path.exists() else 0o644
            descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
            temporary_files.append(temporary)
            with os.fdopen(descriptor, "wb") as output:
                os.fchmod(output.fileno(), mode)
                output.write(contents)
                output.flush()
                os.fsync(output.fileno())
        for path, temporary in zip(writes, temporary_files):
            os.replace(temporary, path)
    except BaseException:
        for temporary in temporary_files:
            if os.path.exists(temporary):
                os.unlink(temporary)
        raise


def update(root, fetch=http_get, api_base="https://api.github.com"):
    root = Path(root)
    if not api_base.startswith("https://"):
        raise ValueError("GitHub API base must use HTTPS")
    tag = latest_release(fetch, api_base)
    version = tag[1:]
    commit = resolve_commit(fetch, api_base, tag)
    css_url = immutable_url(commit, "github-markdown.css")
    license_url = immutable_url(commit, "license")
    source_css = fetch(css_url)
    license_contents = fetch(license_url)
    if not source_css or not license_contents:
        raise ValueError("upstream CSS and license must be non-empty")
    vendored_css = remove_redundant_eof_blank_line(source_css)
    source_hash = sha256(source_css)
    vendored_hash = sha256(vendored_css)

    manifest_path = root / "compliance/third-party-license-sources.tsv"
    rows, (old_index, old_columns) = parse_manifest(manifest_path)
    old_path = NOTICE_PATH.fullmatch(old_columns[1])
    if (old_columns[0] != "notice" or not old_path
            or not re.fullmatch(r"github-markdown-css [0-9]+\.[0-9]+\.[0-9]+", old_columns[4])):
        raise ValueError("github-markdown-css notice manifest row is unsafe")
    old_version = old_columns[4].removeprefix("github-markdown-css ")
    path_version = ".".join(old_path.groups())
    old_url = re.fullmatch(
        rf"https://raw\.githubusercontent\.com/{OWNER}/{REPOSITORY}/([0-9a-f]{{40}})/license",
        old_columns[3],
    )
    if old_version != path_version or not old_url:
        raise ValueError("github-markdown-css notice manifest row is inconsistent")
    if version_tuple(version) < version_tuple(old_version):
        raise ValueError(f"refusing to downgrade github-markdown-css from {old_version} to {version}")
    if version == old_version and old_url.group(1) != commit:
        raise ValueError(f"refusing moved release tag: {tag}")
    old_notice = root / old_columns[1]
    old_hash = old_columns[2]
    if not re.fullmatch(r"[0-9a-f]{64}", old_hash):
        raise ValueError("old notice manifest hash is invalid")
    if old_notice.is_symlink() or not old_notice.is_file() or sha256(old_notice.read_bytes()) != old_hash:
        raise ValueError(f"refusing to replace unverified notice: {old_notice}")

    notice_relative = f"THIRD_PARTY_NOTICES/github-markdown-css-{version}-license"
    new_notice = root / notice_relative
    new_hash = sha256(license_contents)
    if new_notice.is_symlink() or (new_notice.exists() and (not new_notice.is_file() or sha256(new_notice.read_bytes()) != new_hash)):
        raise ValueError(f"refusing to overwrite changed notice: {new_notice}")
    rows[old_index] = "\t".join(("notice", notice_relative, new_hash, license_url, f"github-markdown-css {version}"))
    version_contents = (
        f"github-markdown-css: {version}\n"
        f"tag: {tag}\n"
        f"immutable-commit: {commit}\n"
        f"immutable-source: {css_url}\n"
        f"source-sha256: {source_hash}\n"
        f"vendored-sha256: {vendored_hash}\n"
    ).encode()
    version_path = root / "src/vendor/github-markdown.css.version"
    current_version = re.findall(
        r"^github-markdown-css: ([0-9]+\.[0-9]+\.[0-9]+)$",
        version_path.read_text(encoding="utf-8"),
        flags=re.MULTILINE,
    )
    if current_version != [old_version]:
        raise ValueError("CSS version record does not match notice manifest")
    readme = (root / "README.md").read_text(encoding="utf-8")
    readme_pattern = re.compile(
        r"\[github-markdown-css v([0-9]+\.[0-9]+\.[0-9]+)\]"
        r"\(https://github\.com/sindresorhus/github-markdown-css/releases/tag/"
        r"v[0-9]+\.[0-9]+\.[0-9]+\)"
    )
    readme_versions = readme_pattern.findall(readme)
    if readme_versions != [old_version]:
        raise ValueError("README CSS version does not match notice manifest")
    readme, count = readme_pattern.subn(
        f"[github-markdown-css {tag}](https://github.com/{OWNER}/{REPOSITORY}/releases/tag/{tag})",
        readme,
    )
    if count != 1:
        raise ValueError("expected one current github-markdown-css README release link")
    # Validate all inputs before replacing any tracked file.
    writes = {
        root / "src/vendor/github-markdown.css": vendored_css,
        version_path: version_contents,
        root / "README.md": readme.encode(),
        manifest_path: ("\n".join(rows) + "\n").encode(),
        new_notice: license_contents,
    }
    for path in writes:
        if not path.parent.is_dir():
            raise ValueError(f"missing destination directory: {path.parent}")
    atomic_replace_all(writes)
    if old_notice != new_notice:
        old_notice.unlink()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--api-base", default="https://api.github.com")
    arguments = parser.parse_args()
    update(arguments.root, api_base=arguments.api_base)


if __name__ == "__main__":
    main()
