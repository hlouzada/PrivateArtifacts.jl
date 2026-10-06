# Private Download entries

Private artifact downloads are defined similarly to regular artifacts in `Artifacts.toml`
(see [#Artifacts.toml-files](https://pkgdocs.julialang.org/v1/artifacts/#Artifacts.toml-files)),
they share the same `[[<name>]]` platform tables containing the `git-tree-sha1`, `os`, and `arch` fields,
but uses `[[<name>.download_private]]` tables instead of `[[<name>.download]]` tables. Each entry contains
the usual `url` and `sha256` fields, an optional `kind` field and extra options depending on the kind
(see [#Source Kinds](@ref "Source Kinds")).

```toml
[[libtbos]]
os = "linux"
arch = "x86_64"
git-tree-sha1 = "0123456789abcdef0123456789abcdef01234567"

    [[libtbos.download_private]]
    url = "s3://private-artifacts/libtbos-x86_64-linux-gnu.tar.gz"
    sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    [[libtbos.download_private]]
    url = "https://downloads.example.com/libtbos.tar.gz"
    sha256 = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
    kind = "http"

[[libtbos]]
os = "windows"
arch = "x86_64"
git-tree-sha1 = "fedcba9876543210fedcba9876543210fedcba98"

    [[libtbos.download_private]]
    url = "https://github.com/private-artifacts/libtbos/releases/download/v0.1.0/libtbos-x86_64-windows-msvc.tar.gz"
    sha256 = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
```

As with `Artifacts.jl`, the hash of the unpacked artifact needs to match `git-tree-sha1`
and so does `sha256` against the downloaded archive. Artifact locations in `Overrides.toml`
take precedence over `download_private` entries.
