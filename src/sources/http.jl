const TOKEN_PLACEHOLDER = "{token}"
const DEFAULT_HEADERS = ("Authorization" => "Bearer $TOKEN_PLACEHOLDER",)
# `Host` would send the token to another virtual host behind the same server.
# The others control the connection, which belongs to libcurl.
const FORBIDDEN_HEADERS = (
    "host", "connection", "content-length", "keep-alive", "proxy-authorization", "proxy-connection",
    "te", "trailer", "transfer-encoding", "upgrade",
)

# `K` is the kind. It selects the method of `cli_token`.
struct HeaderSource{K} <: Source
    url::String
    host::String
    headers::Headers
    HeaderSource{K}(url, headers) where {K} = new{K}(url, https_host(url), Tuple(headers))
end

const HTTPSource = HeaderSource{:http}

function parse_headers(settings::AbstractDict, artifact::AbstractString)::Headers
    headers = get(settings, "headers", nothing)
    headers === nothing && return DEFAULT_HEADERS
    headers isa AbstractDict || error("The `headers` of artifact `$artifact` must be a table of strings.")
    Tuple(map(sort!(collect(headers); by = first)) do (name, value)
        contains(name, r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+\z") || error("Invalid header name `$(shown(name))` for artifact `$artifact`.")
        lowercase(name) in FORBIDDEN_HEADERS && error("Artifact `$artifact` must not set the header `$name`.")
        # libcurl rejects a NUL with an error that would show the header and its token.
        value isa AbstractString && isvalid(value) && !contains(replace(value, '\t' => ' '), CONTROL) || error(
            "The header `$name` of artifact `$artifact` must be a string without control characters.",
        )
        String(name) => String(value)
    end)
end

function header_source(kind::Symbol, url::AbstractString, settings::AbstractDict, artifact::AbstractString)::HeaderSource
    check_settings(settings, ("headers",), String(kind), artifact)
    HeaderSource{kind}(url, parse_headers(settings, artifact))
end

cli_token(source::HTTPSource, artifact::AbstractString)::String = no_token_error(source.host, artifact)

function request_headers(source::HeaderSource, artifact::AbstractString)::Tuple{Vector{Pair{String, String}}, Vector{String}}
    secrets = [name for (name, value) in source.headers if occursin(TOKEN_PLACEHOLDER, value)]
    isempty(secrets) && return collect(source.headers), secrets
    token = find_token(source.host, artifact)
    token === nothing && (token = cli_token(source, artifact))
    check_token(token, source.host)
    [name => replace(value, TOKEN_PLACEHOLDER => token) for (name, value) in source.headers], secrets
end

fetch_archive(source::HeaderSource, archive::AbstractString, artifact::AbstractString)::Nothing =
    download_archive(source.url, archive, request_headers(source, artifact)...)
