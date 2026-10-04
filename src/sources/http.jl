const TOKEN_PLACEHOLDER = "{token}"
const DEFAULT_HEADERS = ["Authorization" => "Bearer $TOKEN_PLACEHOLDER"]
# `Host` would send the token to another virtual host behind the same server.
# The others control the connection, which belongs to libcurl.
const FORBIDDEN_HEADERS = (
    "host", "connection", "content-length", "keep-alive", "proxy-authorization", "proxy-connection",
    "te", "trailer", "transfer-encoding", "upgrade",
)

struct HTTPSource <: Source
    url::String
    host::String
    headers::Vector{Pair{String, String}}
end

function parse_headers(settings::AbstractDict, artifact::AbstractString)::Vector{Pair{String, String}}
    headers = get(settings, "headers", nothing)
    headers === nothing && return copy(DEFAULT_HEADERS)
    headers isa AbstractDict || error("The `headers` of artifact `$artifact` must be a table of strings.")
    map(sort!(collect(headers); by = first)) do (name, value)
        contains(name, r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+\z") || error("Invalid header name `$(shown(name))` for artifact `$artifact`.")
        lowercase(name) in FORBIDDEN_HEADERS && error("Artifact `$artifact` must not set the header `$name`.")
        # libcurl rejects a NUL with an error that would show the header and its token.
        value isa AbstractString && isvalid(value) && !contains(replace(value, '\t' => ' '), CONTROL) || error(
            "The header `$name` of artifact `$artifact` must be a string without control characters.",
        )
        String(name) => String(value)
    end
end

function http_source(url::AbstractString, settings::AbstractDict, artifact::AbstractString)::HTTPSource
    check_settings(settings, ("headers",), "http", artifact)
    HTTPSource(url, https_authority(url, artifact), parse_headers(settings, artifact))
end

cli_token(source::HTTPSource, artifact::AbstractString)::String = no_token_error(source.host, artifact)

# `source` needs the fields of an `HTTPSource` and a method of `cli_token`.
function request_headers(source::Source, artifact::AbstractString)::Tuple{Vector{Pair{String, String}}, Vector{String}}
    secrets = [name for (name, value) in source.headers if occursin(TOKEN_PLACEHOLDER, value)]
    isempty(secrets) && return source.headers, secrets
    token = find_token(source.host, artifact)
    token === nothing && (token = cli_token(source, artifact))
    check_token(token, source.host)
    [name => replace(value, TOKEN_PLACEHOLDER => token) for (name, value) in source.headers], secrets
end

fetch_archive(source::HTTPSource, archive::AbstractString, artifact::AbstractString)::Nothing =
    download_archive(source.url, archive, request_headers(source, artifact)...)
