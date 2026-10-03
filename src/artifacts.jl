"""
    artifact"name"
    @artifact_str(name, platform = HostPlatform())

Path of the artifact `name` from the `Artifacts.toml` of the package or project
that contains the calling file. REPL input uses the working directory.
`name/sub/path` gives a path inside the artifact. `name` can be any expression
that gives a `String`, and `platform` selects among platform-specific entries.

An artifact with `[[name.download_private]]` entries that is not installed is
fetched from the first entry that succeeds, in order. The archive must match
the `sha256` of that entry and unpack to the `git-tree-sha1` of the artifact.

Other artifacts go to `Artifacts.@artifact_str`. A literal `name` without a
`platform` is looked up when the macro expands, other forms when they run.
"""
macro artifact_str(name, platform = nothing)
    passthrough(name, platform) = Expr(:macrocall, GlobalRef(Artifacts, Symbol("@artifact_str")), __source__, name, platform)
    # The same lookup of `Artifacts.toml` as `Artifacts.@artifact_str`.
    srcfile = string(__source__.file)
    if ((isinteractive() && startswith(srcfile, "REPL[")) || (!isinteractive() && srcfile == "none")) && !isfile(srcfile)
        srcfile = pwd()
    end
    artifacts_toml = Artifacts.find_artifacts_toml(srcfile)
    # Escaped so that the macro of Artifacts sees the module of the caller.
    artifacts_toml === nothing && return esc(passthrough(name, platform))
    artifact_dict = Artifacts.load_artifacts_toml(artifacts_toml)
    @static if VERSION >= v"1.11"
        include_dependency(artifacts_toml; track_content = true)
    else
        include_dependency(artifacts_toml)
    end
    if name isa AbstractString && platform === nothing
        artifact, subpath = String.(Artifacts.split_artifact_slash(String(name)))
        meta = private_meta(artifact, artifact_dict, artifacts_toml, Base.BinaryPlatforms.HostPlatform())
        meta === nothing && return esc(passthrough(name, platform))
        return :(private_artifact_path($__module__, $artifacts_toml, $artifact_dict, $artifact, $subpath, $meta))
    end
    platform === nothing && (platform = Base.BinaryPlatforms.HostPlatform())
    name_var, platform_var, meta_var = gensym(:name), gensym(:platform), gensym(:meta)
    lookup = GlobalRef(@__MODULE__, :private_lookup)
    install = GlobalRef(@__MODULE__, :private_artifact_path)
    esc(quote
        let $platform_var = $platform, $name_var = $name
            $meta_var = $lookup($name_var, $artifact_dict, $artifacts_toml, $platform_var)
            if $meta_var === nothing
                $(passthrough(name_var, platform_var))
            else
                $install($__module__, $artifacts_toml, $artifact_dict, $meta_var...)
            end
        end
    end)
end

function private_meta(artifact::AbstractString, artifact_dict::AbstractDict, artifacts_toml::AbstractString, platform)::Union{AbstractDict, Nothing}
    meta = Artifacts.artifact_meta(artifact, artifact_dict, artifacts_toml; platform)
    (meta === nothing || !haskey(meta, "download_private")) && return nothing
    meta
end

# A missing `name` raises the error of `Artifacts.@artifact_str`.
function private_lookup(name::AbstractString, artifact_dict::AbstractDict, artifacts_toml::AbstractString, platform)::Union{Tuple{String, String, AbstractDict}, Nothing}
    artifact, subpath, _ = Artifacts.artifact_slash_lookup(name, artifact_dict, artifacts_toml, platform)
    meta = private_meta(artifact, artifact_dict, artifacts_toml, platform)
    meta === nothing ? nothing : (String(artifact), String(subpath), meta)
end

function private_artifact_path(mod::Module, artifacts_toml::AbstractString, artifact_dict::AbstractDict, artifact::AbstractString, subpath::AbstractString, meta::AbstractDict)::String
    uuid = Base.PkgId(mod).uuid
    uuid === nothing || Artifacts.process_overrides(artifact_dict, uuid)
    path = ensure_installed(artifact, meta, artifacts_toml)
    isempty(subpath) ? path : joinpath(path, subpath)
end

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
