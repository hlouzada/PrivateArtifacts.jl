# One `[[name.download_private]]` entry. Subtypes implement
# `fetch_archive(source, archive, artifact)` to write the archive to the path `archive`.
abstract type Source end

const Headers = Tuple{Vararg{Pair{String, String}}}

function check_settings(settings::AbstractDict, allowed::Tuple{Vararg{AbstractString}}, kind::AbstractString, artifact::AbstractString)::Nothing
    for key in keys(settings)
        key in allowed || error(
            "Unknown key `$(shown(key))` in a `[[$artifact.download_private]]` entry of kind `$kind`. " *
            (isempty(allowed) ? "It takes no other keys." : "Allowed keys besides `url`, `sha256` and `kind`: $(join(allowed, ", "))."),
        )
    end
end

no_token_error(host::AbstractString, artifact::AbstractString, hint::AbstractString = "") = error(
    "No token for $host to download artifact `$artifact`. " *
    "Set $(host_token_env(host)) or $(artifact_token_env(artifact))$hint.",
)
