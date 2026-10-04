using Test
using Artifacts
using Downloads
using TOML
using Pkg
using Sockets
using PrivateArtifacts
using PrivateArtifacts: GitHubSource, GitLabSource, HTTPSource, S3Source

const PA = PrivateArtifacts

function write_artifacts_toml(directory, artifacts)
    path = joinpath(directory, "Artifacts.toml")
    open(io -> TOML.print(io, artifacts), path, "w")
    path
end

source_of(url; settings...) =
    PA.parse_source(Dict{String, Any}("url" => url, "sha256" => "0"^64, (String(k) => v for (k, v) in settings)...), "my_lib").source

# An executable `name` in `bin` that records its arguments and some environment
# variables in `bin/name.log` and then runs `body`. With `append` every call adds
# to the log.
function fake_cli(bin, name, body = ""; variables = (), append = false)
    log = joinpath(bin, "$name.log")
    recorded = join(("\"\$$variable\"" for variable in variables), " ")
    write(joinpath(bin, name), """
        #!/bin/sh
        printf '%s\\n' "\$@" $recorded $(append ? ">>" : ">") '$log'
        $body
        """)
    chmod(joinpath(bin, name), 0o755)
    log
end

# The configuration of the machine must not reach the tests, and a test run
# from a terminal must not ask for a login.
const AMBIENT = [
    [
        name => nothing for name in keys(ENV)
        if startswith(name, "JULIA_PA_") && name != "JULIA_PA_LOGIN" ||
            name in ("GH_CONFIG_DIR", "GLAB_CONFIG_DIR", "AWS_CONFIG_FILE", "AWS_SHARED_CREDENTIALS_FILE", "AWS_PROFILE") ||
            name in PA.AWS_CREDENTIAL_SOURCE_ENVS
    ];
    "JULIA_PA_LOGIN" => "false"
]

withenv(AMBIENT...) do
    include("environment.jl")
    include("urls.jl")
    include("sources/entries.jl")
    include("redirects.jl")
    if !Sys.iswindows()
        include("sources/http.jl")
        include("sources/gitlab.jl")
    end
    include("sources/github.jl")
    include("sources/s3.jl")
    include("installation.jl")
end
