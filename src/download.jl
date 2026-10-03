const REDIRECT_STATUSES = (301, 302, 303, 307, 308)
const MAX_REDIRECTS = 10
const DEFAULT_PORTS = Dict("http" => ":80", "https" => ":443")

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
encode_location(location::AbstractString)::String =
    replace(location, r"[^\x21-\x7E]" => c -> join("%" * uppercase(string(byte; base = 16, pad = 2)) for byte in codeunits(c)))

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

function redirect_target(url::AbstractString, response)::String
    index = findfirst(((name, _),) -> lowercase(name) == "location", response.headers)
    # Downloads drops a header that is not valid UTF-8.
    index === nothing && error("The redirect from $(redact(url)) has no valid `Location` header.")
    target = resolve_reference(url, encode_location(String(strip(last(response.headers[index])))))
    scheme = match(r"^(https?)://"i, target)
    scheme !== nothing && !(startswith(lowercase(url), "https:") && lowercase(scheme[1]) == "http") || error(
        "Refusing the redirect from $(redact(url)) to $(redact(target)).",
    )
    target
end

# Keeps the existing hook. A new downloader has the global `Downloads.EASY_HOOK`.
function with_curl_options(f::Function, downloader::Downloads.Downloader, options::Pair...)
    hook = downloader.easy_hook
    downloader.easy_hook = (easy, info) -> begin
        hook === nothing || hook(easy, info)
        for (option, value) in options
            Downloads.Curl.setopt(easy, option, value)
        end
    end
    try
        f()
    finally
        downloader.easy_hook = hook
    end
end

# Redirects are followed here because libcurl forwards every header except
# `Authorization` to another host. The headers named in `secrets` are dropped once
# a redirect leaves the origin of `url`.
function download_archive(
    url::AbstractString, archive::AbstractString, headers::AbstractVector, secrets::AbstractVector;
    downloader::Downloads.Downloader = Downloads.Downloader(),
)::Nothing
    with_curl_options(downloader, Downloads.Curl.CURLOPT_FOLLOWLOCATION => false) do
        start, current = origin(url), url
        for redirects in 0:MAX_REDIRECTS
            failure = try
                Downloads.download(current, archive; headers, downloader)
                return nothing
            catch err
                err isa Downloads.RequestError || rethrow()
                err
            end
            # Errors are thrown outside the `catch` so that the request error is not
            # shown as their cause. The URL of a redirect target can hold a signature.
            # The status line comes from the server and may hold control characters.
            if !(failure.response.status in REDIRECT_STATUSES)
                message = sprint(showerror, failure)
                redirects == 0 && error(escape_controls(message))
                error("Downloading $(escape_string(url)) failed after a redirect: $(escape_controls(replace(message, current => redact(current))))")
            end
            current = redirect_target(current, failure.response)
            origin(current) == start || (headers = filter(((name, _),) -> !(name in secrets), headers))
        end
        error("Too many redirects from $(escape_string(url)).")
    end
end

# Mirrors when Pkg ignores a tree hash mismatch. Without symlink permission on
# Windows, unpacking copies the symlinks and changes the tree hash.
function ignore_hashes()::Bool
    value = env("JULIA_PKG_IGNORE_HASHES")
    if value !== nothing
        ignore = Base.get_bool_env("JULIA_PKG_IGNORE_HASHES", false)
        ignore === nothing && error("JULIA_PKG_IGNORE_HASHES must be true or false, got `$value`.")
        return ignore
    end
    # Pkg before Julia 1.10.1 has no `can_symlink` and no default for Windows.
    Sys.iswindows() && isdefined(Pkg.Artifacts, :can_symlink) &&
        !mktempdir(Pkg.Artifacts.can_symlink, first(Artifacts.artifacts_dirs()))
end

exit_status(process)::String = process.termsignal > 0 ? "signal $(process.termsignal)" : "exit code $(process.exitcode)"

function install_archive(artifact::AbstractString, hash::Base.SHA1, source::Source, sha256::AbstractString)::Nothing
    mktempdir() do directory
        archive = joinpath(directory, "archive")
        fetch_archive(source, archive, artifact)
        isfile(archive) || error("Fetching artifact `$artifact` produced no archive.")
        archive_sha256 = bytes2hex(open(SHA.sha256, archive))
        archive_sha256 == sha256 || error(
            "The archive of artifact `$artifact` has sha256 $archive_sha256, expected $sha256.",
        )
        # Before Julia 1.12 the error of a failed unpack shows the environment of
        # the unpacking program including tokens. It is replaced outside the `catch`.
        # Exceptions that callers are handling stay below `depth`.
        depth = length(current_exceptions())
        unpacked = try
            Pkg.Artifacts.create_artifact(dir -> Pkg.PlatformEngines.unpack(archive, dir))
        catch err
            spawned(error) = error isa ProcessFailedException || error isa Base.IOError && startswith(error.msg, "could not spawn")
            any(spawned(entry.exception) for entry in current_exceptions()[(depth + 1):end]) || rethrow()
            err
        end
        unpacked isa InterruptException && throw(InterruptException())
        unpacked isa Exception && error(
            "The archive of artifact `$artifact` could not be unpacked" *
            (unpacked isa ProcessFailedException ? ", $(join((exit_status(process) for process in unpacked.procs), ", "))." : "."),
        )
        unpacked == hash && return
        message = "Artifact `$artifact` unpacked to git-tree-sha1 $(bytes2hex(unpacked.bytes)), expected $(bytes2hex(hash.bytes))."
        ignore_hashes() || error(message)
        @error "$message Ignoring the mismatch like Pkg does."
        # Copied next to the target and renamed so that the target is never partial.
        target = Artifacts.artifact_path(hash)
        mktempdir(dirname(target)) do staging
            cp(Artifacts.artifact_path(unpacked), joinpath(staging, "tree"))
            # Another process may have installed the artifact in the meantime.
            try
                mv(joinpath(staging, "tree"), target)
            catch
                Artifacts.artifact_exists(hash) || rethrow()
            end
        end
    end
    nothing
end
