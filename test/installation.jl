@testset "artifact installation" begin
    @test all(method -> method.module !== PrivateArtifacts, methods(Pkg.PlatformEngines.download))

    mktempdir() do directory
        archive = joinpath(directory, "my_lib.tar.gz")
        hash, sha256 = Artifacts.with_artifacts_directory(joinpath(directory, "source")) do
            hash = Pkg.Artifacts.create_artifact(dir -> write(joinpath(dir, "data.txt"), "data"))
            hash, Pkg.Artifacts.archive_artifact(hash, archive)
        end
        tree_hash = bytes2hex(hash.bytes)
        public_archive = joinpath(directory, "public_lib.tar.gz")
        public_hash, public_sha256 = Artifacts.with_artifacts_directory(joinpath(directory, "source")) do
            public_hash = Pkg.Artifacts.create_artifact(dir -> write(joinpath(dir, "public.txt"), "public"))
            public_hash, Pkg.Artifacts.archive_artifact(public_hash, public_archive)
        end
        public_tree_hash = bytes2hex(public_hash.bytes)
        local_source = HTTPSource("file://$archive", "localhost", [])
        wrong = "0"^40

        Artifacts.with_artifacts_directory(joinpath(directory, "wrong_sha256")) do
            @test_throws "The archive of artifact `my_lib` has sha256 $sha256, expected $("0"^64)" PA.install_archive(
                "my_lib", hash, local_source, "0"^64,
            )
            @test !Artifacts.artifact_exists(hash)
        end
        if !Sys.iswindows()
            @test PA.exit_status(run(ignorestatus(`sh -c 'kill -9 $$'`))) == "signal 9"
            @test PA.exit_status(run(ignorestatus(`sh -c 'exit 2'`))) == "exit code 2"
        end
        # Before Julia 1.12 the error of the unpacking program shows the environment.
        Artifacts.with_artifacts_directory(joinpath(directory, "junk")) do
            junk = joinpath(directory, "junk.bin")
            write(junk, rand(UInt8, 1000))
            junk_sha256 = bytes2hex(open(PA.SHA.sha256, junk))
            message = withenv("SECRET_FOR_TEST" => "leaked-secret") do
                try
                    PA.install_archive("my_lib", hash, HTTPSource("file://$junk", "localhost", []), junk_sha256)
                catch
                    join((sprint(showerror, error.exception) for error in current_exceptions()), "\n")
                end
            end
            @test startswith(message, "The archive of artifact `my_lib` could not be unpacked")
            @test !occursin("leaked-secret", message) && !occursin('\n', message)
        end
        # Other errors of the artifact store keep their own message. Root ignores
        # the permission.
        if !Sys.iswindows() && ccall(:getuid, Cuint, ()) != 0
            store = joinpath(directory, "read_only")
            mkpath(store)
            chmod(store, 0o555)
            Artifacts.with_artifacts_directory(store) do
                @test_throws r"permission denied" PA.install_archive("my_lib", hash, local_source, sha256)
                # Also while the caller handles a failed process.
                try
                    run(`false`)
                catch
                    @test_throws r"permission denied" PA.install_archive("my_lib", hash, local_source, sha256)
                end
            end
            chmod(store, 0o755)
        end
        Artifacts.with_artifacts_directory(joinpath(directory, "wrong_tree_hash")) do
            withenv("JULIA_PKG_IGNORE_HASHES" => nothing) do
                @test_throws "Artifact `my_lib` unpacked to git-tree-sha1 $tree_hash, expected $wrong" PA.install_archive(
                    "my_lib", Base.SHA1(wrong), local_source, sha256,
                )
                @test !Artifacts.artifact_exists(Base.SHA1(wrong))
            end
            withenv("JULIA_PKG_IGNORE_HASHES" => "maybe") do
                @test_throws "JULIA_PKG_IGNORE_HASHES must be true or false, got `maybe`" PA.install_archive(
                    "my_lib", Base.SHA1(wrong), local_source, sha256,
                )
            end
            withenv("JULIA_PKG_IGNORE_HASHES" => "\e[2J") do
                @test_throws "JULIA_PKG_IGNORE_HASHES must be true or false, got `\\u001b[2J`." PA.ignore_hashes()
            end
            # Pkg's override for file systems that change tree hashes.
            withenv("JULIA_PKG_IGNORE_HASHES" => "true") do
                @test_logs (:error, "Artifact `my_lib` unpacked to git-tree-sha1 $tree_hash, expected $wrong. Ignoring the mismatch like Pkg does.") PA.install_archive(
                    "my_lib", Base.SHA1(wrong), local_source, sha256,
                )
                @test read(joinpath(Artifacts.artifact_path(Base.SHA1(wrong)), "data.txt"), String) == "data"
            end
        end

        project = joinpath(directory, "project")
        mkdir(project)
        s3_entry(key, checksum = sha256) = Dict("url" => "s3://my-bucket/$key", "sha256" => checksum)
        https_entry = Dict("url" => "https://files.example.invalid/my_lib.tar.gz", "sha256" => sha256)
        artifacts_toml = write_artifacts_toml(project, Dict(
            "my_lib" => Dict("git-tree-sha1" => tree_hash, "download_private" => [s3_entry("missing"), s3_entry("bad_sha", "0"^64), s3_entry("lib")]),
            "single" => Dict("git-tree-sha1" => wrong, "download_private" => [s3_entry("missing")]),
            "invalid_second" => Dict("git-tree-sha1" => tree_hash, "download_private" => [s3_entry("lib"), Dict("url" => "s3://my-bucket/lib")]),
            "http_lib" => Dict("git-tree-sha1" => wrong, "download_private" => [https_entry]),
            "public_lib" => Dict("git-tree-sha1" => public_tree_hash, "download" => [https_entry]),
            "lazy_lib" => Dict("git-tree-sha1" => public_tree_hash, "lazy" => true, "download" => [
                Dict("url" => "file://$public_archive", "sha256" => public_sha256),
            ]),
            "table" => Dict("git-tree-sha1" => wrong, "download_private" => https_entry),
            "empty" => Dict("git-tree-sha1" => wrong, "download_private" => []),
            "other_platform" => [Dict("os" => Sys.iswindows() ? "linux" : "windows", "arch" => "x86_64", "git-tree-sha1" => wrong)],
            "platform_lib" => [
                Dict("os" => os, "arch" => "x86_64", "git-tree-sha1" => wrong, "download_private" => [
                    Dict("url" => "https://$os.example.invalid/platform_lib.tar.gz", "sha256" => sha256),
                ]) for os in ("linux", "windows")
            ],
        ))
        # The macro reads the `Artifacts.toml` next to the file that uses it.
        function use(code, source = joinpath(project, "use.jl"); setup = "using PrivateArtifacts", mod = Module())
            write(source, "$setup\n$code")
            Base.include(mod, source)
        end
        artifact(name, source = joinpath(project, "use.jl"); setup = "using PrivateArtifacts") = use("artifact\"$name\"", source; setup)
        platform(os) = "Base.BinaryPlatforms.Platform(\"x86_64\", \"$os\")"

        Artifacts.with_artifacts_directory(joinpath(directory, "store")) do
            @test_throws "No token for files.example.invalid to download artifact `http_lib`" artifact("http_lib")
            @test_throws "`download_private` of artifact `table` in $artifacts_toml must be written as `[[table.download_private]]` tables" artifact("table")
            @test_throws "must be written as `[[empty.download_private]]` tables" artifact("empty")

            # Everything without `download_private` goes to `Artifacts.@artifact_str`.
            @test_throws "Cannot locate artifact 'missing'" artifact("missing")
            @test_throws "Cannot locate artifact 'other_platform'" artifact("other_platform")
            bare = joinpath(directory, "bare")
            mkdir(bare)
            write(joinpath(bare, "Project.toml"), "")
            @test_throws "Cannot locate '(Julia)Artifacts.toml' file when attempting to use artifact 'my_lib'" artifact("my_lib", joinpath(bare, "use.jl"))
            @test_throws "Artifact \"lazy_lib\" is a lazy artifact; package developers must call `using LazyArtifacts`" artifact("lazy_lib")
            public_path = Artifacts.artifact_path(public_hash)
            withenv("JULIA_PKG_SERVER" => "") do
                @test artifact("lazy_lib"; setup = "using PrivateArtifacts\nimport LazyArtifacts") == public_path
            end
            @test artifact("public_lib") == public_path
            @test read(artifact("public_lib/public.txt"), String) == "public"
            for call in ("name = \"public_lib\"\n@artifact_str(name)", "@artifact_str(\"public_lib\", Base.BinaryPlatforms.HostPlatform())")
                @test use(call) == public_path
            end
            @test_throws "Cannot locate artifact 'missing' for x86_64-linux-gnu" use("name = \"missing\"\n@artifact_str(name, $(platform("linux")))")

            # Names computed at run time and explicit platforms.
            @test_throws "No token for files.example.invalid to download artifact `http_lib`" use("name = \"http_lib\"\n@artifact_str(name)")
            @test_throws "No token for files.example.invalid to download artifact `http_lib`" use("@artifact_str(\"http_lib/a/b\", Base.BinaryPlatforms.HostPlatform())")
            for os in ("linux", "windows")
                @test_throws "No token for $os.example.invalid to download artifact `platform_lib`" use("@artifact_str(\"platform_lib\", $(platform(os)))")
            end
            @test_throws "Cannot locate artifact 'platform_lib' for x86_64-apple-darwin" use("@artifact_str(\"platform_lib\", $(platform("macos")))")

            if !Sys.iswindows()
                bin = joinpath(directory, "bin")
                mkdir(bin)
                fake_cli(bin, "aws", """
                    case "\$3" in
                        s3://my-bucket/missing) exit 1;;
                        s3://my-bucket/bad_sha) printf corrupt > "\$4";;
                        *) cp '$archive' "\$4";;
                    esac
                    """)
                withenv("PATH" => "$bin:/usr/bin:/bin") do
                    # Every entry is checked before the first download, which would succeed here.
                    @test_throws "Expected a `[[invalid_second.download_private]]` entry to have a `sha256`" artifact("invalid_second")
                    @test !Artifacts.artifact_exists(hash)

                    @test_throws "`aws s3 cp` failed for artifact `single` from s3://my-bucket/missing" artifact("single")
                    # A path inside the artifact installs it too.
                    path = @test_logs(
                        (:info, "Downloading private artifact `my_lib`"),
                        (:warn, "Fetching private artifact `my_lib` from s3://my-bucket/missing failed. Trying the next entry."),
                        (:info, "Downloading private artifact `my_lib`"),
                        (:warn, "Fetching private artifact `my_lib` from s3://my-bucket/bad_sha failed. Trying the next entry."),
                        (:info, "Downloading private artifact `my_lib`"),
                        artifact("my_lib/data.txt"),
                    )
                    @test path == joinpath(Artifacts.artifact_path(hash), "data.txt")
                    @test read(path, String) == "data"
                end
            end
            PA.install_archive("my_lib", hash, local_source, sha256)
            # An installed artifact needs no credentials.
            withenv("PATH" => "") do
                @test (@test_logs artifact("my_lib")) == Artifacts.artifact_path(hash)
                @test (@test_logs use("name = \"my_lib/data.txt\"\n@artifact_str(name)")) == joinpath(Artifacts.artifact_path(hash), "data.txt")
            end
        end

        # `Overrides.toml` can replace an artifact of a package by name.
        store = joinpath(directory, "overrides")
        mkpath(store)
        uuid = Base.UUID("4f8a7c64-58a1-4b8e-9b55-5e8b0c6f0b2a")
        write(joinpath(store, "Overrides.toml"), "[$uuid]\nhttp_lib = \"$(escape_string(project))\"\n")
        package = Module()
        ccall(:jl_set_module_uuid, Cvoid, (Any, NTuple{2, UInt64}), package, (UInt64(uuid.value >> 64), UInt64(uuid.value % UInt64)))
        Artifacts.with_artifacts_directory(store) do
            try
                Artifacts.load_overrides(force = true)
                # A module with a UUID may load only its dependencies by name.
                @test use("artifact\"http_lib/use.jl\""; setup = "using ..PrivateArtifacts", mod = package) == joinpath(project, "use.jl")
            finally
                rm(joinpath(store, "Overrides.toml"))
                Artifacts.load_overrides(force = true)
            end
        end
    end
end
