# One `[[name.download_private]]` entry. Subtypes implement
# `fetch_archive(source, archive, artifact)` to write the archive to the path `archive`.
abstract type Source end

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

function check_settings(settings::AbstractDict, allowed::Tuple{Vararg{AbstractString}}, kind::AbstractString, artifact::AbstractString)::Nothing
    for key in keys(settings)
        key in allowed || error(
            "Unknown key `$(shown(key))` in a `[[$artifact.download_private]]` entry of kind `$kind`. " *
            (isempty(allowed) ? "It takes no other keys." : "Allowed keys besides `url`, `sha256` and `kind`: $(join(allowed, ", "))."),
        )
    end
end

shown(value)::String = escape_string(string(value))

unescape(path::AbstractString)::String = replace(path, r"%[0-9A-Fa-f]{2}" => hex -> String([parse(UInt8, hex[2:3]; base = 16)]))
