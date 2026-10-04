"""
Authenticated downloads for artifacts that `Artifacts.toml` lists with
`[[name.download_private]]` entries. [`@artifact_str`](@ref) installs them on
first use. Tokens and CLI configuration directories are read from `JULIA_PA_*`
environment variables on every download.
"""
module PrivateArtifacts

using Artifacts: Artifacts
using Downloads: Downloads
using JSON: JSON
using Pkg: Pkg
using SHA: SHA

export @artifact_str

include("text.jl")
include("config.jl")
include("urls.jl")
include("cli.jl")
include("download.jl")
include("sources/source.jl")
include("sources/http.jl")
include("sources/gitlab.jl")
include("sources/github.jl")
include("sources/s3.jl")
include("sources/entries.jl")
include("install.jl")
include("macro.jl")

end
