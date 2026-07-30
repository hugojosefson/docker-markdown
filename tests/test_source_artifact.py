import hashlib
import json
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "source-artifact.py"
POLICY = ROOT / "source-artifact-policy.json"
SUBJECT = "example.invalid/markdown@sha256:" + "1" * 64


def run(*args, check=True):
    return subprocess.run(["python3", HELPER, *map(str, args)], text=True, capture_output=True, check=check)


class SourceArtifactTests(unittest.TestCase):
    def normalized(self, directory):
        files = []
        for architecture in ("amd64", "arm64"):
            output = directory / f"{architecture}.json"
            run("normalize", "--architecture", architecture, "--input", ROOT / f"tests/fixtures/apk-{architecture}.json", "--output", output)
            files.append(output)
        merged = directory / "merged.json"
        run("merge", "--policy", POLICY, "--input", *files, "--output", merged)
        return merged

    def test_normalize_is_canonical(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "inventory.json"
            run("normalize", "--architecture", "amd64", "--input", ROOT / "tests/fixtures/apk-amd64.json", "--output", output)
            self.assertEqual(output.read_text(), json.dumps(json.loads(output.read_text()), indent=2, sort_keys=True) + "\n")

    def test_platforms_requires_one_manifest_per_architecture(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            image_index = directory / "index.json"
            image_index.write_text(json.dumps({"manifests": [
                {"digest": "sha256:" + "1" * 64, "platform": {"os": "linux", "architecture": "amd64"}},
                {"digest": "sha256:" + "2" * 64, "platform": {"os": "linux", "architecture": "arm64", "variant": "v8"}},
            ]}))
            result = run("platforms", "--input", image_index)
            self.assertEqual(result.stdout.splitlines(), ["amd64\tsha256:" + "1" * 64, "arm64\tsha256:" + "2" * 64])
            image_index.write_text(json.dumps({"manifests": []}))
            self.assertNotEqual(run("platforms", "--input", image_index, check=False).returncode, 0)

    def test_merge_uses_policy_patterns_and_full_commits(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            merged = self.normalized(directory)
            data = json.loads(merged.read_text())
            self.assertEqual(
                [item["origin"] for item in data["selected"]],
                ["busybox", "busybox", "eclipse", "musl"],
            )
            custom_policy = directory / "policy.json"
            custom_policy.write_text(json.dumps({
                "artifactType": "application/vnd.hugojosefson.markdown.source.v1",
                "plantumlCommit": "b" * 40,
                "copyleftLicensePatterns": ["ZLIB"],
            }))
            run("merge", "--policy", custom_policy, "--input", directory / "amd64.json", directory / "arm64.json", "--output", directory / "custom.json")
            self.assertEqual(json.loads((directory / "custom.json").read_text())["selected"][0]["origin"], "zlib")

    def test_merge_rejects_unsafe_selected_reference(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            bad = directory / "bad.json"
            bad.write_text(json.dumps({"architecture": "amd64", "packages": [{"name": "bad", "version": "1", "arch": "x86_64", "license": "GPL-2.0", "origin": "../bad", "commit": "A" * 40}]}))
            arm = directory / "arm.json"
            arm.write_text(json.dumps({"architecture": "arm64", "packages": []}))
            result = run("merge", "--policy", POLICY, "--input", bad, arm, "--output", directory / "output.json", check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unsafe origin", result.stderr)

    def test_merge_rejects_selected_package_without_source_reference(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            bad = directory / "bad.json"
            bad.write_text(json.dumps({"architecture": "amd64", "packages": [{"name": "virtual", "version": "1", "arch": "x86_64", "license": "GPL-2.0-only", "origin": "", "commit": ""}]}))
            arm = directory / "arm.json"
            arm.write_text(json.dumps({"architecture": "arm64", "packages": []}))
            result = run("merge", "--policy", POLICY, "--input", bad, arm, "--output", directory / "output.json", check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("lacks origin or commit", result.stderr)

    def test_verify_requires_exact_safe_file_set_and_mappings(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            source = directory / "source"
            source.mkdir()
            (source / "alpine").mkdir()
            (source / "project").mkdir()
            (source / "plantuml").mkdir()
            (source / "python").mkdir()
            archive = source / "alpine/pkg.tar"
            archive.write_bytes(b"dummy\n")
            project_archive = source / ("project/" + "a" * 40 + ".tar")
            project_archive.write_bytes(b"project\n")
            plantuml_archive = source / "plantuml/plantuml-1.2026.6.tar"
            plantuml_archive.write_bytes(b"plantuml\n")
            python_archive = source / "python/dummy-1.0.tar.gz"
            python_archive.write_bytes(b"python\n")
            index = source / "source-index.json"
            entries = [
                {"path": path.relative_to(source).as_posix(), "sha256": "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest(), "size": path.stat().st_size}
                for path in (archive, plantuml_archive, project_archive, python_archive)
            ]
            entries.sort(key=lambda item: item["path"])
            valid = {
                "schema": 1,
                "artifactType": "application/vnd.hugojosefson.markdown.source.v1",
                "release": "v1.2.3",
                "git": "a" * 40,
                "image": SUBJECT,
                "selection": {"licenseContains": ["GPL", "LGPL", "EPL", "MPL"]},
                "components": {
                    "project": {"archive": project_archive.relative_to(source).as_posix(), "commit": "a" * 40},
                    "plantuml": {"archive": plantuml_archive.relative_to(source).as_posix(), "version": "1.2026.6", "commit": "6287b33c5d1be2f7b0d480687d0b5a1accbd7971"},
                    "python": {"archives": [python_archive.relative_to(source).as_posix()], "requirements": "requirements.txt in the project archive"},
                },
                "inventories": [
                    {"architecture": "amd64", "packages": []},
                    {"architecture": "arm64", "packages": []},
                ],
                "selected": [],
                "mappings": [],
                "sources": entries,
                "modifications": {},
            }
            index.write_text(json.dumps(valid))
            run("verify", "--index", index, "--source-dir", source, "--policy", POLICY, "--artifact-type", valid["artifactType"], "--release", "v1.2.3", "--subject", SUBJECT)
            valid["selection"]["licenseContains"] = ["MIT"]
            index.write_text(json.dumps(valid))
            self.assertNotEqual(run("verify", "--index", index, "--source-dir", source, "--policy", POLICY, check=False).returncode, 0)
            valid["selection"]["licenseContains"] = ["GPL", "LGPL", "EPL", "MPL"]
            index.write_text(json.dumps(valid))
            (source / "extra").write_text("extra")
            self.assertNotEqual(run("verify", "--index", index, "--source-dir", source, "--policy", POLICY, check=False).returncode, 0)
            (source / "extra").unlink()
            valid["sources"][0]["path"] = "../escape"
            index.write_text(json.dumps(valid))
            self.assertNotEqual(run("verify", "--index", index, "--source-dir", source, "--policy", POLICY, check=False).returncode, 0)

    def test_archive_is_deterministic_and_rejects_symlinks(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            source = directory / "source"
            source.mkdir()
            executable = source / "run"
            executable.write_text("dummy\n")
            executable.chmod(0o755)
            first, second = directory / "one.tar", directory / "two.tar"
            run("archive", "--source-dir", source, "--output", first)
            run("archive", "--source-dir", source, "--output", second)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            with tarfile.open(first) as archive:
                member = archive.getmember("run")
                self.assertEqual(member.uid, 0)
                self.assertEqual(member.mtime, 0)
                self.assertEqual(member.mode, 0o755)
            (source / "link").symlink_to("run")
            self.assertNotEqual(run("archive", "--source-dir", source, "--output", directory / "bad.tar", check=False).returncode, 0)

    def test_collect_dry_run_rejects_mutable_and_invalid_tags(self):
        script = ROOT / "source-artifact.sh"
        bad_image = subprocess.run([script, "collect", "example.invalid/markdown:latest", "v1.2.3", "out", "--dry-run"], text=True, capture_output=True)
        self.assertNotEqual(bad_image.returncode, 0)
        bad_tag = subprocess.run([script, "collect", SUBJECT, "1.2.3", "out", "--dry-run"], text=True, capture_output=True)
        self.assertNotEqual(bad_tag.returncode, 0)


if __name__ == "__main__":
    unittest.main()
