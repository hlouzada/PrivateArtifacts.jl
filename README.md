# PrivateArtifacts.jl

[![CI](https://github.com/hlouzada/PrivateArtifacts.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/hlouzada/PrivateArtifacts.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/hlouzada/PrivateArtifacts.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/hlouzada/PrivateArtifacts.jl)
[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://hlouzada.github.io/PrivateArtifacts.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://hlouzada.github.io/PrivateArtifacts.jl/dev/)

`PrivateArtifacts` implements authenticated downloads from private sources to
Julia's artifact system. It behaves similarly to `LazyArtifacts.jl`.

Credentials come from environment variables or from the command-line tools that already manage
them for each service: [`gh`](https://cli.github.com/) for GitHub,
[`glab`](https://gitlab.com/gitlab-org/cli) for GitLab and the
[AWS CLI](https://aws.amazon.com/cli/) for S3 (see [Authentication](https://hlouzada.github.io/PrivateArtifacts.jl/dev/authentication/)).

## Artifacts.toml

Private artifacts are declared in `Artifacts.toml` like regular artifacts. The
`[[<name>.download]]` tables are replaced by `[[<name>.download_private]]` tables. Each entry
has the usual `url` and `sha256` fields. The source kind is inferred from the URL, or set
with the `kind` field (see
[Private Download entries](https://hlouzada.github.io/PrivateArtifacts.jl/dev/artifacts/)).

### GitHub

Release assets and raw files of private repositories:

```toml
[[libtbos]]
os = "linux"
arch = "x86_64"
git-tree-sha1 = "0123456789abcdef0123456789abcdef01234567"

    [[libtbos.download_private]]
    url = "https://github.com/acme/libtbos/releases/download/v0.1.0/libtbos-x86_64-linux-gnu.tar.gz"
    sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

[model]
git-tree-sha1 = "fedcba9876543210fedcba9876543210fedcba98"

    [[model.download_private]]
    url = "https://github.com/acme/model/raw/91f3ecf327d1de943fe076657833252791ba9f60/model.tar.gz"
    sha256 = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
```

The token comes from the first of these that is set:

1. `JULIA_PA_ARTIFACT_TOKEN_<ARTIFACT>`, a token for one artifact, such as
   `JULIA_PA_ARTIFACT_TOKEN_LIBTBOS` or `JULIA_PA_ARTIFACT_TOKEN_MODEL`.
2. `JULIA_PA_HOST_TOKEN_GITHUB_COM`, a token for every artifact on `github.com`.
3. `gh`, the GitHub CLI, with its own login.

```sh
export JULIA_PA_ARTIFACT_TOKEN_LIBTBOS="github_pat_..."
export JULIA_PA_HOST_TOKEN_GITHUB_COM="github_pat_..."
```

With these variables, `libtbos` is downloaded with its own token and `model` with the host
token.

GitHub Enterprise hosts need `kind = "github"` (see
[GitHub](https://hlouzada.github.io/PrivateArtifacts.jl/dev/sources/#GitHub) and
[Token Variables](https://hlouzada.github.io/PrivateArtifacts.jl/dev/authentication/#Token-Variables)).

### S3

Objects in Amazon S3 or an S3-compatible server:

```toml
[data]
git-tree-sha1 = "0123456789abcdef0123456789abcdef01234567"

    [[data.download_private]]
    url = "s3://private-artifacts/releases/data.tar.gz"
    sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    region = "eu-west-1"

    [[data.download_private]]
    url = "s3://artifacts/releases/data.tar.gz"
    sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    host = "minio.example.com:9000"
```

Downloads run `aws s3 cp`, with credentials from the usual AWS CLI credential chain (see
[S3](https://hlouzada.github.io/PrivateArtifacts.jl/dev/sources/#S3)).

[GitLab](https://hlouzada.github.io/PrivateArtifacts.jl/dev/sources/#GitLab) and plain
[HTTP](https://hlouzada.github.io/PrivateArtifacts.jl/dev/sources/#HTTP) sources are also
supported.

## Macro Usage

`PrivateArtifacts` exports an `@artifact_str` macro, it locates `Artifacts.toml` relative
to the source file that contains the call and checks for `download_private` entries. Any
other ones are passed through to `Artifacts.@artifact_str`.

```julia
using PrivateArtifacts

artifact_path = artifact"libtbos"
library_path = artifact"libtbos/lib/libtbos.so"
```

The call forms of `Artifacts.@artifact_str` work the same way for private
artifacts. The name can be computed at run time, and a platform argument
selects among platform-specific entries:

```julia
using Base.BinaryPlatforms: Platform

name = "libtbos"
artifact_path = @artifact_str(name)
windows_path = @artifact_str("libtbos", Platform("x86_64", "windows"))
```
