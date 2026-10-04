function infer_kind(url::AbstractString)::String
    startswith(url, "s3://") && return "s3"
    authority = url_authority(url)
    authority === nothing && return "http"
    github_host(authority) === nothing || return "github"
    authority == GITLAB_COM && return "gitlab"
    s3_endpoint(authority) === nothing || return "s3"
    contains(url, r"^https://[^/?#]+/(?:api/v4/projects/|[^?#]+/-/(?:releases|package_files|raw|jobs)/)") && return "gitlab"
    contains(url, r"^https://[^/?#]+/(?:api/v3/repos/|[^/?#]+/[^/?#]+/releases/download/)") && return "github"
    "http"
end

const SOURCES = Dict("github" => github_source, "gitlab" => gitlab_source, "s3" => s3_source, "http" => http_source)

function parse_source(entry, artifact::AbstractString)::NamedTuple
    context = "a `[[$artifact.download_private]]` entry"
    entry isa AbstractDict || error("Expected $context to be a table, got `$(shown(entry))`.")
    url = get(entry, "url", nothing)
    url isa AbstractString || error("Expected $context to have a string `url`.")
    (!isvalid(url) || contains(url, CONTROL)) && error("The `url` of $context contains a control character or invalid UTF-8: $(shown(url))")
    sha256 = get(entry, "sha256", nothing)
    sha256 isa AbstractString && contains(sha256, r"^[0-9A-Fa-f]{64}\z") || error(
        "Expected $context to have a `sha256` of 64 hexadecimal digits, got `$(shown(sha256))`.",
    )
    kind = get(() -> infer_kind(url), entry, "kind")
    haskey(SOURCES, kind) || error("The `kind` of $context must be one of $(join(sort!(collect(keys(SOURCES))), ", ")), got `$(shown(kind))`.")
    kind == "s3" && startswith(url, "s3://") || https_authority(url, artifact)
    settings = Dict(key => value for (key, value) in entry if !(key in ("url", "sha256", "kind")))
    source = SOURCES[kind](String(url), settings, artifact)
    (; url = String(url), source, sha256 = lowercase(sha256))
end
