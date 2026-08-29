# GitHub Release Options

> See [Guide Usage](../README.md) for how to use these guides.

Configure GitHub Releases to attach build artifacts, add release notes,
and control filename versioning.

## File types

- **substitutedFiles** - tokens in these files are replaced with actual
  values (e.g. version strings) before attaching to the release.
- **verbatimFiles** - attached to the release exactly as they are in the
  repository, with no token replacement.
- **rawFiles** - attached to the release exactly as they are and also expected
  and required to have version already in the file name before the extension.

Both accept comma-separated paths relative to the repository root.

## Options

- `notes` - custom release notes text. Leave empty (`''`) for
  auto-generated notes based on commits since the last release.
- `addVersionToFilenames` - when `true`, the version is appended to
  each attached filename (e.g. `output-1.2.3.txt`).
- `consumerReferenceForms` - which references the "How to Consume" section
  of the auto-generated notes shows, and in what order:
  - `short-only` (default) - the org-local reference alone, e.g.
    `my-app:[1.2.3]`. Right for private in-house work that is never
    consumed from outside.
  - `short-first` - both, org-local reference first.
  - `full-first` - both, fully qualified reference first. Right for open
    source projects used inside and outside the org.
  - `full-only` - the fully qualified reference alone, e.g.
    `ghcr.io/my-org/my/my-app:[1.2.3]`. Right for vendor packages
    consumed only from other orgs.

  The short form resolves against the consumer's own registry and
  namespace defaults, so it only reaches this org. The full form carries
  registry, namespace, prefix and name, and works from anywhere. Flavours
  with no consumable artifact (docker, spec, basic versioning) have no
  "How to Consume" section and ignore this setting.

## Notes

- The `enabled: false` flag is required to deactivate GitHub Releases.
- Paths configured that do not exist at release time cause a failure.
