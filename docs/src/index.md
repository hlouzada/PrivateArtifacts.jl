# PrivateArtifacts.jl

`PrivateArtifacts` implements authenticated downloads from private sources to
Julia's artifact system. It behaves similarly to `LazyArtifacts.jl`.

Credentials come from environment variables or from the command-line tools that already manage
them for each service: [`gh`](https://cli.github.com/) for GitHub,
[`glab`](https://gitlab.com/gitlab-org/cli) for GitLab and the
[AWS CLI](https://aws.amazon.com/cli/) for S3 (see [Authentication](@ref)).

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
