# rmapi-fork

This directory contains a trimmed fork of [`github.com/ddvk/rmapi`](https://github.com/ddvk/rmapi)
(module path `github.com/juruen/rmapi`), used to build `zotbridge-localgeta`:
a small CLI that merges a reMarkable document's on-device `.rm` annotation
strokes into its original PDF **entirely locally**, with no cloud round-trip.

## Why this exists

reMarkable's own `xochitl` app stores every piece rmapi's cloud-based
`geta -a` command needs to do annotation merging directly on the device's
filesystem already:

```
<uuid>.content        # page list / firmware metadata
<uuid>.pdf             # original, un-annotated PDF
<uuid>/<page>.rm        # per-page annotation strokes
```

`rmapi geta` normally re-downloads a zip of exactly these files from
reMarkable's cloud and hands it to its own `archive`+`annotations` Go
packages, which do the actual `.rm`-to-PDF compositing (via `unidoc/unipdf`,
under its free "Community" license tier). Since the tablet already has
these files locally, the cloud fetch is pure overhead — and on our device,
it was also the root cause of a multi-second/retry-loop delay in
reverse-sync.

## What's changed vs. upstream

Only the packages needed for annotation merging were kept: `archive`,
`annotations`, `encoding/rm`, `log`, `util`, `model`. Everything else
(the interactive `shell` package, cloud API client, sync engine, etc.)
was dropped — this fork never talks to the network.

Two additions were made on top of unmodified upstream logic:

- **`archive/local.go`** — adds `(*Zip).ReadFromDir(dir, uuid string) error`,
  which populates a `Zip` struct straight from a document's on-disk files
  instead of from a downloaded zip archive. It reuses the exact same
  page-map-building logic as the zip-based reader (extracted into a shared
  `buildPageMapFromContent()` in `archive/reader.go`) so firmware 3.0+
  `cPages` documents are handled identically either way.
- **`annotations/pdf.go`** — adds `CreatePdfGeneratorFromZip(...)`, letting
  `PdfGenerator.Generate()` work from an already-populated `*archive.Zip`
  instead of only from a zip file path.
- **`cmd/zotbridge-localgeta/main.go`** — the CLI entry point tying the
  above together: `-library <xochitl-dir> -uuid <uuid> -output <file.pdf>
  [-a] [-n] [-p]`.

All upstream tests (`archive`, `annotations`, `encoding/rm`) still pass
unmodified against this fork.

## License

Upstream `rmapi` is licensed under the **GNU AGPL-3.0** (see `LICENSE` in
this directory). This fork, including `zotbridge-localgeta`, is a
derivative work and is distributed under the same AGPL-3.0 terms. If you
redistribute a build of `zotbridge-localgeta` (or a modified version of
this fork), you must make its complete corresponding source available
under AGPL-3.0, same as upstream.

## Building

Requires Go 1.23+. From this directory:

```sh
GOOS=linux GOARCH=arm64 go build -o zotbridge-localgeta ./cmd/zotbridge-localgeta
```

See `scripts/build-zotbridge-localgeta.ps1` in the repo root for the
Windows/WSL build helper used by `scripts/package-tablet.ps1`.
