const DEFAULT_PORTS = Dict("http" => ":80", "https" => ":443")

function url_authority(url::AbstractString)::Union{String, Nothing}
    m = match(r"^https://([A-Za-z0-9.-]+)(:[0-9]+)?(?:[/?#]|\z)", url)
    m === nothing && return nothing
    host = lowercase(m[1])
    all(label -> contains(label, r"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z"), split(host, '.')) || return nothing
    m[2] in (nothing, ":443") ? host : host * m[2]
end

function https_authority(url::AbstractString, artifact::AbstractString)::String
    authority = url_authority(url)
    authority === nothing && error("The URL of private artifact `$artifact` is not a plain https URL: $url")
    authority
end

function origin(url::AbstractString)::String
    scheme, authority = lowercase.(something(match(r"^([A-Za-z][A-Za-z0-9+.-]*)://([^/?#]*)", url)).captures)
    "$scheme://" * chopsuffix(authority, get(DEFAULT_PORTS, scheme, ""))
end

# User info, path and query of a redirect target can hold a secret.
function redact(url::AbstractString)::String
    m = match(r"^([A-Za-z][A-Za-z0-9+.-]*:)(?://(?:[^/?#]*@)?([^/?#]*))?", url)
    m === nothing ? "…" : m[2] === nothing ? escape_string(m[1]) * "…" : escape_string("$(m[1])//$(m[2])") * "/…"
end

# libcurl encodes the same characters in a redirect target but writes a space in
# the query as `+`.
encode_location(location::AbstractString)::String = percent_encode(location, r"[^\x21-\x7E]")

function remove_dot_segments(path::AbstractString)::String
    segments = split(path, '/')
    output = SubString{String}[]
    for (index, segment) in pairs(segments)
        if segment == ".."
            length(output) > 1 && pop!(output)
        elseif segment != "."
            push!(output, segment)
        end
        # A path that ends in `.` or `..` names a directory.
        index == lastindex(segments) && segment in (".", "..") && push!(output, "")
    end
    join(output, '/')
end

# Reference resolution of RFC 3986.
function resolve_reference(url::AbstractString, reference::AbstractString)::String
    reference = replace(reference, r"#.*"s => "")
    root, path, query = something(match(r"^([A-Za-z][A-Za-z0-9+.-]*://[^/?#]*)([^?#]*)(\?[^#]*)?", url)).captures
    target =
        contains(reference, r"^[A-Za-z][A-Za-z0-9+.-]*:") ? reference :
        startswith(reference, "//") ? first(split(root, "//")) * reference :
        isempty(reference) ? root * path * something(query, "") :
        startswith(reference, "?") ? root * path * reference :
        startswith(reference, "/") ? root * reference :
        root * (isempty(path) ? "/" : path[1:findlast('/', path)]) * reference
    m = match(r"^([A-Za-z][A-Za-z0-9+.-]*://[^/?#]*)([^?#]*)(.*)\z"s, target)
    m === nothing ? target : m[1] * remove_dot_segments(m[2]) * m[3]
end
