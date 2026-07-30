#!/usr/bin/env python3
"""Deterministic metadata and archives for source OCI artifacts."""
import argparse
import hashlib
import json
import re
import tarfile
from pathlib import Path, PurePosixPath

FIELDS = ("name", "version", "arch", "license", "origin", "commit")
COMMIT = re.compile(r"^[0-9a-f]{40}$")
ORIGIN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$")
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
RELEASE = re.compile(r"^v[0-9]+\.[0-9]+\.[0-9]+$")
SUBJECT = re.compile(r"^[^@\s]+@sha256:[0-9a-f]{64}$")


def canonical(value):
    return json.dumps(value, sort_keys=True, indent=2) + "\n"


def load_policy(path):
    policy = json.load(path.open(encoding="utf-8"))
    patterns = policy.get("copyleftLicensePatterns")
    if not isinstance(patterns, list) or not patterns or not all(isinstance(p, str) and p for p in patterns):
        raise ValueError("policy copyleftLicensePatterns must be a non-empty string list")
    return policy


def packages(value):
    if isinstance(value, dict):
        for key in ("packages", "results"):
            if isinstance(value.get(key), list):
                value = value[key]
                break
    if not isinstance(value, list):
        raise ValueError("apk JSON must contain a package list")
    result = []
    for package in value:
        if not isinstance(package, dict):
            raise ValueError("apk package must be an object")
        item = {field: package.get(field, "") for field in FIELDS}
        if not all(isinstance(item[field], str) for field in FIELDS):
            raise ValueError("apk package fields must be strings")
        if not item["name"] or not item["version"] or not item["arch"]:
            raise ValueError("apk package lacks name, version, or arch")
        result.append(item)
    return sorted(result, key=lambda item: tuple(item[field] for field in FIELDS))


def validate_origin_commit(item):
    if not item["origin"] or not item["commit"]:
        raise ValueError("selected package lacks origin or commit: " + item["name"])
    if not ORIGIN.fullmatch(item["origin"]):
        raise ValueError("selected package has unsafe origin: " + item["name"])
    if not COMMIT.fullmatch(item["commit"]):
        raise ValueError("selected package has unsafe commit: " + item["name"])


def selected(inventories, patterns):
    result = []
    for inventory in inventories:
        for package in inventory["packages"]:
            if any(pattern.upper() in package["license"].upper() for pattern in patterns):
                validate_origin_commit(package)
                result.append(package)
    return sorted(result, key=lambda item: (item["origin"], item["commit"], item["name"], item["arch"]))


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return "sha256:" + digest.hexdigest()


def safe_relative(value):
    if not isinstance(value, str) or not value or "\\" in value:
        return False
    path = PurePosixPath(value)
    return not path.is_absolute() and all(part not in ("", ".", "..") for part in path.parts)


def source_files(source_dir):
    files = []
    for path in sorted(source_dir.rglob("*")):
        relative = path.relative_to(source_dir).as_posix()
        if path.is_symlink():
            raise ValueError("source contains symlink: " + relative)
        if not (path.is_file() or path.is_dir()):
            raise ValueError("source contains unsupported entry: " + relative)
        if path.is_file() and relative != "source-index.json":
            files.append({"path": relative, "sha256": sha256(path), "size": path.stat().st_size})
    return files


def command_normalize(args):
    args.output.write_text(canonical({"architecture": args.architecture, "packages": packages(json.load(args.input))}), encoding="utf-8")


def command_platforms(args):
    index = json.load(args.input)
    manifests = index.get("manifests") if isinstance(index, dict) else None
    if not isinstance(manifests, list):
        raise ValueError("subject is not a multi-platform image index")
    for architecture in ("amd64", "arm64"):
        matches = []
        for manifest in manifests:
            platform = manifest.get("platform", {}) if isinstance(manifest, dict) else {}
            if platform.get("os") == "linux" and platform.get("architecture") == architecture:
                digest = manifest.get("digest")
                if isinstance(digest, str) and DIGEST.fullmatch(digest):
                    matches.append(digest)
        if len(matches) != 1:
            raise ValueError("image index must contain exactly one linux/{} manifest".format(architecture))
        print("{}\t{}".format(architecture, matches[0]))


def command_merge(args):
    policy = load_policy(args.policy)
    inventories = [json.load(path.open(encoding="utf-8")) for path in args.input]
    if not all(isinstance(item, dict) and isinstance(item.get("architecture"), str) for item in inventories):
        raise ValueError("inventory lacks architecture")
    inventories = sorted(inventories, key=lambda item: item["architecture"])
    if [item["architecture"] for item in inventories] != ["amd64", "arm64"]:
        raise ValueError("inventories must contain exactly amd64 and arm64")
    for inventory in inventories:
        inventory["packages"] = packages(inventory.get("packages"))
    args.output.write_text(canonical({"schema": 1, "inventories": inventories,
                                      "selected": selected(inventories, policy["copyleftLicensePatterns"])}), encoding="utf-8")


def command_index(args):
    policy = load_policy(args.policy)
    inventory = json.load(args.inventory.open(encoding="utf-8"))
    if not isinstance(inventory, dict) or not isinstance(inventory.get("inventories"), list) or not isinstance(inventory.get("selected"), list):
        raise ValueError("invalid merged inventory")
    mappings = []
    for item in inventory["selected"]:
        validate_origin_commit(item)
        archive = "alpine/{}-{}.tar".format(item["origin"], item["commit"])
        mappings.append({"package": item["name"], "architecture": item["arch"], "archive": archive})
    if not RELEASE.fullmatch(args.release) or not COMMIT.fullmatch(args.git) or not SUBJECT.fullmatch(args.image):
        raise ValueError("invalid source-index identity")
    files = source_files(args.source_dir)
    source_paths = {item["path"] for item in files}
    project_archive = "project/{}.tar".format(args.git)
    plantuml_archive = "plantuml/plantuml-{}.tar".format(args.plantuml_version)
    python_archives = sorted(path for path in source_paths if path.startswith("python/"))
    if project_archive not in source_paths or plantuml_archive not in source_paths or not python_archives:
        raise ValueError("source directory lacks project, PlantUML, or Python sources")
    if (not isinstance(policy.get("artifactType"), str)
            or not COMMIT.fullmatch(str(policy.get("plantumlCommit", "")))
            or args.plantuml_commit != policy["plantumlCommit"]):
        raise ValueError("invalid source artifact policy identity")
    if not COMMIT.fullmatch(args.plantuml_commit):
        raise ValueError("invalid PlantUML commit")
    output = {"schema": 1, "artifactType": policy["artifactType"], "release": args.release,
              "git": args.git, "image": args.image,
              "selection": {"licenseContains": policy["copyleftLicensePatterns"]},
              "components": {
                  "project": {"archive": project_archive, "commit": args.git},
                  "plantuml": {"archive": plantuml_archive, "version": args.plantuml_version,
                                "commit": args.plantuml_commit},
                  "python": {"archives": python_archives,
                             "requirements": "requirements.txt in the project archive"},
              },
              "inventories": inventory["inventories"], "selected": inventory["selected"],
              "mappings": mappings, "sources": files,
              "modifications": {
                  "project": "Git archive of the release commit",
                  "thirdParty": "Upstream files and Alpine packaging files; tar ownership and timestamps normalized",
              }}
    args.output.write_text(canonical(output), encoding="utf-8")


def command_verify(args):
    policy = load_policy(args.policy)
    index = json.load(args.index.open(encoding="utf-8"))
    required = {"schema", "artifactType", "release", "git", "image", "selection", "components",
                "inventories", "selected", "mappings", "sources", "modifications"}
    if not isinstance(index, dict) or set(index) != required or index["schema"] != 1:
        raise ValueError("invalid source-index schema")
    if (not all(isinstance(index[key], str) for key in ("artifactType", "release", "git", "image"))
            or not RELEASE.fullmatch(index["release"]) or not COMMIT.fullmatch(index["git"])
            or not SUBJECT.fullmatch(index["image"])):
        raise ValueError("invalid source-index identity")
    if args.artifact_type and index["artifactType"] != args.artifact_type:
        raise ValueError("artifact type does not match source-index")
    if index["artifactType"] != policy.get("artifactType"):
        raise ValueError("source-index does not match source artifact policy")
    if args.release and index["release"] != args.release:
        raise ValueError("release does not match source-index")
    if args.subject and index["image"] != args.subject:
        raise ValueError("subject does not match source-index")
    if (not all(isinstance(index[key], list) for key in ("inventories", "selected", "mappings", "sources"))
            or not isinstance(index["selection"], dict) or not isinstance(index["components"], dict)
            or set(index["selection"]) != {"licenseContains"}
            or not isinstance(index["modifications"], dict)):
        raise ValueError("invalid source-index lists")
    patterns = index["selection"]["licenseContains"]
    if not isinstance(patterns, list) or not patterns or not all(isinstance(pattern, str) and pattern for pattern in patterns):
        raise ValueError("invalid source-index selection policy")
    if patterns != policy["copyleftLicensePatterns"]:
        raise ValueError("source-index does not match source artifact policy")
    if [item.get("architecture") for item in index["inventories"] if isinstance(item, dict)] != ["amd64", "arm64"]:
        raise ValueError("source-index inventories must contain amd64 and arm64")
    for inventory in index["inventories"]:
        if not isinstance(inventory, dict) or set(inventory) != {"architecture", "packages"}:
            raise ValueError("invalid inventory entry")
        if inventory["packages"] != packages(inventory["packages"]):
            raise ValueError("inventory packages are not canonical")
    for item in index["selected"]:
        if not isinstance(item, dict) or any(not isinstance(item.get(field), str) for field in FIELDS):
            raise ValueError("invalid selected package")
        validate_origin_commit(item)
    if index["selected"] != selected(index["inventories"], patterns):
        raise ValueError("selected packages do not match inventories and policy")
    expected = {}
    for item in index["sources"]:
        if not isinstance(item, dict) or set(item) != {"path", "sha256", "size"} or not safe_relative(item.get("path")):
            raise ValueError("invalid source entry")
        if (item["path"] in expected or isinstance(item["size"], bool)
                or not isinstance(item["size"], int) or item["size"] < 0
                or not isinstance(item["sha256"], str) or not DIGEST.fullmatch(item["sha256"])):
            raise ValueError("invalid or duplicate source entry: " + str(item.get("path")))
        expected[item["path"]] = item
    actual = {item["path"]: item for item in source_files(args.source_dir)}
    if set(actual) != set(expected):
        raise ValueError("source file set does not match source-index")
    for path, item in expected.items():
        if actual[path]["sha256"] != item["sha256"] or actual[path]["size"] != item["size"]:
            raise ValueError("checksum or size mismatch: " + path)
    components = index["components"]
    if set(components) != {"project", "plantuml", "python"}:
        raise ValueError("invalid source components")
    project = components["project"]
    plantuml = components["plantuml"]
    python = components["python"]
    if (not isinstance(project, dict) or set(project) != {"archive", "commit"}
            or not all(isinstance(project.get(key), str) for key in ("archive", "commit"))
            or project["commit"] != index["git"] or project["archive"] not in expected):
        raise ValueError("invalid project source component")
    if (not isinstance(plantuml, dict) or set(plantuml) != {"archive", "commit", "version"}
            or not isinstance(plantuml.get("version"), str) or not plantuml["version"]
            or not isinstance(plantuml.get("commit"), str) or not COMMIT.fullmatch(plantuml["commit"])
            or not isinstance(plantuml.get("archive"), str)
            or plantuml.get("archive") not in expected):
        raise ValueError("invalid PlantUML source component")
    if plantuml["commit"] != policy.get("plantumlCommit"):
        raise ValueError("PlantUML source does not match source artifact policy")
    if (not isinstance(python, dict) or set(python) != {"archives", "requirements"}
            or python.get("requirements") != "requirements.txt in the project archive"
            or not isinstance(python.get("archives"), list) or not python["archives"]
            or python["archives"] != sorted(python["archives"])
            or any(not isinstance(path, str) or not path.startswith("python/") or path not in expected
                   for path in python["archives"])):
        raise ValueError("invalid Python source component")
    expected_mappings = []
    for item in index["selected"]:
        expected_mappings.append({
            "package": item["name"],
            "architecture": item["arch"],
            "archive": "alpine/{}-{}.tar".format(item["origin"], item["commit"]),
        })
    if index["mappings"] != expected_mappings:
        raise ValueError("source mappings do not match selected packages")
    for mapping in index["mappings"]:
        if not isinstance(mapping, dict) or set(mapping) != {"package", "architecture", "archive"} or not all(isinstance(mapping.get(key), str) for key in ("package", "architecture", "archive")) or not safe_relative(mapping["archive"]) or not mapping["archive"].endswith(".tar") or mapping["archive"] not in expected:
            raise ValueError("mapping does not point to a listed source archive")


def command_archive(args):
    if args.source_dir.is_symlink() or not args.source_dir.is_dir():
        raise ValueError("archive source must be a directory")
    entries = []
    for path in sorted(args.source_dir.rglob("*")):
        relative = path.relative_to(args.source_dir).as_posix()
        if path.is_symlink() or not (path.is_file() or path.is_dir()):
            raise ValueError("unsupported archive entry: " + relative)
        entries.append((path, relative))
    with tarfile.open(args.output, "w") as archive:
        for path, relative in entries:
            info = archive.gettarinfo(str(path), arcname=relative)
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            info.mtime = 0
            info.mode = 0o755 if info.isdir() or (info.mode & 0o111) else 0o644
            info.pax_headers = {}
            if info.isfile():
                with path.open("rb") as stream:
                    archive.addfile(info, stream)
            else:
                archive.addfile(info)


def parser():
    root = argparse.ArgumentParser()
    commands = root.add_subparsers(required=True)
    normalize = commands.add_parser("normalize"); normalize.add_argument("--architecture", required=True); normalize.add_argument("--input", type=argparse.FileType("r"), required=True); normalize.add_argument("--output", type=Path, required=True); normalize.set_defaults(function=command_normalize)
    platforms = commands.add_parser("platforms"); platforms.add_argument("--input", type=argparse.FileType("r"), required=True); platforms.set_defaults(function=command_platforms)
    merge = commands.add_parser("merge"); merge.add_argument("--input", type=Path, nargs="+", required=True); merge.add_argument("--policy", type=Path, required=True); merge.add_argument("--output", type=Path, required=True); merge.set_defaults(function=command_merge)
    index = commands.add_parser("index"); index.add_argument("--inventory", type=Path, required=True); index.add_argument("--source-dir", type=Path, required=True); index.add_argument("--output", type=Path, required=True); index.add_argument("--policy", type=Path, required=True); index.add_argument("--release", required=True); index.add_argument("--git", required=True); index.add_argument("--image", required=True); index.add_argument("--plantuml-version", required=True); index.add_argument("--plantuml-commit", required=True); index.set_defaults(function=command_index)
    verify = commands.add_parser("verify"); verify.add_argument("--index", type=Path, required=True); verify.add_argument("--source-dir", type=Path, required=True); verify.add_argument("--policy", type=Path, required=True); verify.add_argument("--artifact-type"); verify.add_argument("--release"); verify.add_argument("--subject"); verify.set_defaults(function=command_verify)
    archive = commands.add_parser("archive"); archive.add_argument("--source-dir", type=Path, required=True); archive.add_argument("--output", type=Path, required=True); archive.set_defaults(function=command_archive)
    return root


if __name__ == "__main__":
    arguments = parser().parse_args()
    try:
        arguments.function(arguments)
    except (ValueError, OSError, tarfile.TarError, json.JSONDecodeError) as error:
        raise SystemExit("source-artifact: " + str(error))
