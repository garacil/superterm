# Reference corpus policy

[`index.md`](index.md) is the reviewed source-of-truth catalogue for terminal,
transport, compiler, library, and platform behavior used by SuperTerm.

Primary upstream links are preferred. A third-party document is copied into
this repository only when its provenance is exact and its redistribution terms
permit that copy. Otherwise the catalogue keeps an official link and, when a
stable upstream artifact is available, its SHA-256 digest. The presence of a
reference never claims that its feature is implemented.

Run `sha256sum -c docs/references/SHA256SUMS` from the repository root to
verify every committed reference-catalogue file.
