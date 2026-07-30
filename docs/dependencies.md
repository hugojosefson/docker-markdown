# Dependency maintenance

## Dependency update checklist

After changing a dependency version:

1. Use the dependency-specific update process when one exists, such as
   [Update GitHub styles](#update-github-styles). Otherwise, pin the version,
   immutable upstream revision, and expected hashes where the dependency is
   declared.
2. Follow [Update dependency notices](#update-dependency-notices).
3. Regenerate affected fixtures as described in
   [Update expected fixtures](../README.md#update-expected-fixtures).
4. If the change affects image packages or collected source, follow
   [When to run source checks](corresponding-source.md#when-to-run-source-checks).
5. Run `deno fmt` and `make test`, then review the full diff.

## Update GitHub styles

Use this when upgrading the vendored GitHub Markdown CSS:

```bash
make update-css
```

[github-markdown.css](../src/vendor/github-markdown.css) currently vendors
[github-markdown-css v5.9.0](https://github.com/sindresorhus/github-markdown-css/releases/tag/v5.9.0),
including automatic light/dark `prefers-color-scheme` support. The update
command discovers the latest stable release, resolves its tag to an immutable
commit, recalculates hashes, stages the versioned notice and provenance for
review, and regenerates local and GitHub API fixtures. It requires existing
[GitHub CLI](https://cli.github.com/) (`gh`) authentication for the GitHub API
fixture refresh.

## Update dependency notices

Notice provenance and checksums live in
[compliance/third-party-license-sources.tsv](../compliance/third-party-license-sources.tsv).

Download only the notice set for review:

```bash
./scripts/download-third-party-licenses.sh --notices-only
```

Omit `--notices-only` to also download the listed source archives:

```bash
./scripts/download-third-party-licenses.sh
```

The script verifies every download and refuses to overwrite a changed review
file. The image stores the project license and approved dependency notices under
`/usr/share/licenses/markdown/`.
