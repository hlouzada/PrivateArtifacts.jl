function ensure_installed(name::AbstractString, meta::AbstractDict, artifacts_toml::AbstractString)::String
    hash = Base.SHA1(meta["git-tree-sha1"])
    Artifacts.artifact_exists(hash) && return Artifacts.artifact_path(hash)
    entries = meta["download_private"]
    entries isa AbstractVector && !isempty(entries) || error(
        "`download_private` of artifact `$name` in $artifacts_toml must be written as `[[$name.download_private]]` tables.",
    )
    sources = [parse_source(entry, name) for entry in entries]
    for (index, (; url, source, sha256)) in enumerate(sources)
        @info "Downloading private artifact `$name`" url
        try
            install_archive(name, hash, source, sha256)
            return Artifacts.artifact_path(hash)
        catch err
            (err isa InterruptException || index == lastindex(sources)) && rethrow()
            @warn "Fetching private artifact `$name` from $url failed. Trying the next entry." exception = (err, catch_backtrace())
        end
    end
end

# Mirrors when Pkg ignores a tree hash mismatch. Without symlink permission on
# Windows, unpacking copies the symlinks and changes the tree hash.
function ignore_hashes()::Bool
    value = env("JULIA_PKG_IGNORE_HASHES")
    if value !== nothing
        ignore = Base.get_bool_env("JULIA_PKG_IGNORE_HASHES", false)
        ignore === nothing && error("JULIA_PKG_IGNORE_HASHES must be true or false, got `$(escape_controls(value))`.")
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
