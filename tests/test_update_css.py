import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import update_css


COMMIT = "a" * 40
TAG_OBJECT = "b" * 40
CSS = b"body { color: black; }\n\n"
NOTICE = b"Dummy notice text for tests only.\n"
OLD_NOTICE = b"Old dummy notice.\n"


def digest(contents):
    return hashlib.sha256(contents).hexdigest()


class CssUpdaterTests(unittest.TestCase):
    def make_root(self, modified_notice=False):
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        (root / "THIRD_PARTY_NOTICES").mkdir()
        old_notice = root / "THIRD_PARTY_NOTICES/github-markdown-css-1.0.0-license"
        old_notice.write_bytes(OLD_NOTICE if not modified_notice else b"Modified dummy notice.\n")
        (root / "third-party-license-sources.tsv").write_text(
            "# kind\tdestination\tsha256\timmutable-or-authoritative-url\tcomponent\n"
            f"notice\tTHIRD_PARTY_NOTICES/github-markdown-css-1.0.0-license\t{digest(OLD_NOTICE)}\thttps://raw.githubusercontent.com/sindresorhus/github-markdown-css/{'c' * 40}/license\tgithub-markdown-css 1.0.0\n"
        )
        (root / "README.md").write_text(
            "[github-markdown-css v1.0.0](https://github.com/sindresorhus/github-markdown-css/releases/tag/v1.0.0)\n"
        )
        (root / "github-markdown.css.version").write_text(
            "github-markdown-css: 1.0.0\n"
        )
        (root / "wrap_end_1.html").write_text("start\n")
        (root / "wrap_end_2.html").write_text("end\n")
        return temporary, root

    def fetch(self, url):
        api = "https://api.github.com/repos/sindresorhus/github-markdown-css"
        responses = {
            f"{api}/releases/latest": json.dumps({"tag_name": "v2.3.4", "prerelease": False, "draft": False}).encode(),
            f"{api}/git/ref/tags/v2.3.4": json.dumps({"object": {"type": "tag", "sha": TAG_OBJECT}}).encode(),
            f"{api}/git/tags/{TAG_OBJECT}": json.dumps({"object": {"type": "commit", "sha": COMMIT}}).encode(),
            update_css.immutable_url(COMMIT, "github-markdown.css"): CSS,
            update_css.immutable_url(COMMIT, "license"): NOTICE,
        }
        return responses[url]

    def test_annotated_tag_updates_all_references_and_is_idempotent(self):
        temporary, root = self.make_root()
        with temporary:
            update_css.update(root, fetch=self.fetch)
            self.assertEqual((root / "github-markdown.css").read_bytes(), CSS[:-1])
            version = (root / "github-markdown.css.version").read_text()
            self.assertIn("github-markdown-css: 2.3.4", version)
            self.assertIn(f"immutable-commit: {COMMIT}", version)
            self.assertIn(update_css.immutable_url(COMMIT, "github-markdown.css"), version)
            self.assertIn(f"source-sha256: {digest(CSS)}", version)
            self.assertIn(f"vendored-sha256: {digest(CSS[:-1])}", version)
            self.assertEqual((root / "wrap_end.html").read_bytes(), b"start\n" + CSS[:-1] + b"end\n")
            self.assertIn("github-markdown-css v2.3.4", (root / "README.md").read_text())
            manifest = (root / "third-party-license-sources.tsv").read_text()
            self.assertIn(f"github-markdown-css-2.3.4-license\t{digest(NOTICE)}", manifest)
            self.assertIn(update_css.immutable_url(COMMIT, "license"), manifest)
            self.assertFalse((root / "THIRD_PARTY_NOTICES/github-markdown-css-1.0.0-license").exists())
            self.assertEqual((root / "THIRD_PARTY_NOTICES/github-markdown-css-2.3.4-license").read_bytes(), NOTICE)
            self.assertEqual((root / "github-markdown.css").stat().st_mode & 0o777, 0o644)
            before = {path.relative_to(root): path.read_bytes() for path in root.rglob("*") if path.is_file()}
            update_css.update(root, fetch=self.fetch)
            after = {path.relative_to(root): path.read_bytes() for path in root.rglob("*") if path.is_file()}
            self.assertEqual(after, before)

    def test_refuses_modified_old_notice_without_writing(self):
        temporary, root = self.make_root(modified_notice=True)
        with temporary:
            with self.assertRaisesRegex(ValueError, "unverified notice"):
                update_css.update(root, fetch=self.fetch)
            self.assertFalse((root / "github-markdown.css").exists())
            self.assertTrue((root / "THIRD_PARTY_NOTICES/github-markdown-css-1.0.0-license").exists())
            self.assertFalse((root / "THIRD_PARTY_NOTICES/github-markdown-css-2.3.4-license").exists())

    def test_rejects_unsafe_notice_path(self):
        temporary, root = self.make_root()
        with temporary:
            manifest = root / "third-party-license-sources.tsv"
            manifest.write_text(
                f"notice\t../outside\t{digest(OLD_NOTICE)}\thttps://example.invalid/license\tgithub-markdown-css 1.0.0\n"
            )
            with self.assertRaisesRegex(ValueError, "unsafe"):
                update_css.update(root, fetch=self.fetch)

    def test_eof_normalization_only_removes_redundant_blank_line(self):
        self.assertEqual(update_css.remove_redundant_eof_blank_line(b"css\n\n"), b"css\n")
        self.assertEqual(update_css.remove_redundant_eof_blank_line(b"css\n"), b"css\n")
        self.assertEqual(update_css.remove_redundant_eof_blank_line(b"css"), b"css")

    def test_refuses_downgrade(self):
        temporary, root = self.make_root()
        with temporary:
            manifest = root / "third-party-license-sources.tsv"
            old_commit = "c" * 40
            old_notice = root / "THIRD_PARTY_NOTICES/github-markdown-css-9.0.0-license"
            old_notice.write_bytes(OLD_NOTICE)
            (root / "THIRD_PARTY_NOTICES/github-markdown-css-1.0.0-license").unlink()
            manifest.write_text(
                f"notice\tTHIRD_PARTY_NOTICES/github-markdown-css-9.0.0-license\t{digest(OLD_NOTICE)}\t{update_css.immutable_url(old_commit, 'license')}\tgithub-markdown-css 9.0.0\n"
            )
            (root / "github-markdown.css.version").write_text("github-markdown-css: 9.0.0\n")
            (root / "README.md").write_text(
                "[github-markdown-css v9.0.0](https://github.com/sindresorhus/github-markdown-css/releases/tag/v9.0.0)\n"
            )
            with self.assertRaisesRegex(ValueError, "downgrade"):
                update_css.update(root, fetch=self.fetch)

    def test_refuses_moved_release_tag(self):
        temporary, root = self.make_root()
        with temporary:
            old_commit = "c" * 40
            old_notice = root / "THIRD_PARTY_NOTICES/github-markdown-css-2.3.4-license"
            old_notice.write_bytes(OLD_NOTICE)
            (root / "THIRD_PARTY_NOTICES/github-markdown-css-1.0.0-license").unlink()
            (root / "third-party-license-sources.tsv").write_text(
                f"notice\tTHIRD_PARTY_NOTICES/github-markdown-css-2.3.4-license\t{digest(OLD_NOTICE)}\t{update_css.immutable_url(old_commit, 'license')}\tgithub-markdown-css 2.3.4\n"
            )
            (root / "github-markdown.css.version").write_text("github-markdown-css: 2.3.4\n")
            (root / "README.md").write_text(
                "[github-markdown-css v2.3.4](https://github.com/sindresorhus/github-markdown-css/releases/tag/v2.3.4)\n"
            )
            with self.assertRaisesRegex(ValueError, "moved release tag"):
                update_css.update(root, fetch=self.fetch)
