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

include("config.jl")
include("sources.jl")
include("http.jl")
include("gitlab.jl")
include("github.jl")
include("s3.jl")
include("entries.jl")
include("download.jl")
include("artifacts.jl")

end
