@testset "GitHub" begin
    @test PA.github_host("github.com") == "github.com"
    @test PA.github_host("api.github.com") == "github.com"
    @test PA.github_host("raw.githubusercontent.com") == "github.com"
    @test PA.github_host("api.acme.ghe.com") == "acme.ghe.com"
    @test PA.github_host("ghe.example.com") === nothing
    @test PA.github_host("api.github.com.example.com") === nothing

    @test PA.api_url("github.com") == "https://api.github.com"
    @test PA.api_url("acme.ghe.com") == "https://api.acme.ghe.com"
    @test PA.api_url("ghe.example.com:8443") == "https://ghe.example.com:8443/api/v3"

    release_url(tag, file) = "https://github.com/acme/project/releases/download/$tag/$file"
    @test source_of(release_url("release/v1.0.0+2", "lib.tar.gz")).location ==
        PA.ReleaseURL("acme", "project", "release/v1.0.0+2", "lib.tar.gz")
    @test source_of("https://GHE.example.com:8443/acme/project/releases/download/v1/lib.tar.gz").location.owner == "acme"
    @test GitHubSource("https://api.github.com/acme/project/releases/download/v1/lib.tar.gz").location === nothing
    @test source_of("https://github.com/acme/project?x/releases/download/v1/lib.tar.gz"; kind = "github").location === nothing
    @test source_of("https://api.github.com/repos/acme/project/releases/assets/1").location === nothing
    @test source_of("https://github.com/acme/project/archive/refs/tags/v1.0.0.tar.gz").location === nothing
    @test GitHubSource(release_url("v1", "lib.tar.gz\n")).location === nothing

    release = Dict(
        "tag_name" => "v1.0.0+2",
        "assets" => [
            Dict("id" => 11, "name" => "lib.tar.gz", "browser_download_url" => release_url("v1.0.0%2B2", "lib.tar.gz")),
            Dict("id" => 12, "name" => "lib+debug.tar.gz", "browser_download_url" => release_url("v1.0.0%2B2", "lib%2Bdebug.tar.gz")),
        ],
    )
    @test PA.asset_id(release, "lib.tar.gz", release_url("v1.0.0+2", "lib.tar.gz")) == 11
    @test PA.asset_id(release, "lib+debug.tar.gz", release_url("v1.0.0+2", "lib+debug.tar.gz")) == 12
    @test PA.asset_id(release, "lib%2Bdebug.tar.gz", release_url("v1.0.0%2B2", "lib%2Bdebug.tar.gz")) == 12
    @test PA.asset_id(release, "lib%2Bdebug.tar.gz", release_url("v1.0.0+2", "lib%2Bdebug.tar.gz")) == 12
    @test_throws "has no asset `missing.tar.gz`. Available assets: lib.tar.gz, lib+debug.tar.gz" PA.asset_id(
        release, "missing.tar.gz", release_url("v1.0.0+2", "missing.tar.gz"),
    )

    # Only release URLs on the web host need the API. These return without a request.
    raw = "https://raw.githubusercontent.com/acme/project/main/lib.tar.gz"
    @test PA.download_url(source_of(raw), "Authorization" => "Bearer secret") == raw
    @test PA.download_headers("https://api.github.com/repos/acme/project/releases/assets/1") == ["Accept" => "application/octet-stream"]
    @test isempty(PA.download_headers("https://api.github.com/repos/acme/project/tarball/v1.0.0"))
    @test isempty(PA.download_headers(raw))

    # Raw file URLs on the web host are downloaded from the contents API.
    contents(api, ref, path) = "$api/repos/acme/project/contents/$path?ref=$ref"
    sha = "91f3ecf327d1de943fe076657833252791ba9f60"
    for (url, expected) in (
        "https://github.com/acme/project/raw/$sha/lib.tar.gz" => contents("https://api.github.com", sha, "lib.tar.gz"),
        "https://www.github.com/acme/project/raw/main/dir/lib%20x.tar.gz" => contents("https://api.github.com", "main", "dir/lib%20x.tar.gz"),
        "https://github.com/acme/project/raw/refs/heads/main/lib.tar.gz" => contents("https://api.github.com", "refs/heads/main", "lib.tar.gz"),
        "https://github.com/acme/project/raw/refs/tags/v1/lib.tar.gz" => contents("https://api.github.com", "refs/tags/v1", "lib.tar.gz"),
        "https://github.com/acme/project/raw/v1.0.0+2/lib.tar.gz" => contents("https://api.github.com", "v1.0.0%2B2", "lib.tar.gz"),
        "https://github.com/acme/project/raw/a&b=c/lib.tar.gz" => contents("https://api.github.com", "a%26b%3Dc", "lib.tar.gz"),
        # A ref with `/` is read as a one-segment ref followed by the path.
        "https://github.com/acme/project/raw/feature/x/lib.tar.gz" => contents("https://api.github.com", "feature", "x/lib.tar.gz"),
        "https://acme.ghe.com/acme/project/raw/main/lib.tar.gz" => contents("https://api.acme.ghe.com", "main", "lib.tar.gz"),
        "https://ghe.example.com:8443/acme/project/raw/main/lib.tar.gz" => contents("https://ghe.example.com:8443/api/v3", "main", "lib.tar.gz"),
    )
        source = occursin("ghe.example.com", url) ? source_of(url; kind = "github") : source_of(url)
        @test PA.download_url(source, "Authorization" => "Bearer secret") == expected
        @test PA.download_headers(expected) == ["Accept" => "application/vnd.github.raw"]
    end
    for url in (
        "https://github.com/acme/project/raw/main/lib.tar.gz?download=1",
        "https://github.com/acme/project/raw/main/",
        "https://github.com/acme/project/raw/main",
        "https://github.com/acme/project/raw/main//lib.tar.gz",
        "https://github.com/acme/project/raw/main/../../other/raw/main/lib.tar.gz",
        "https://github.com/acme/project/raw/%2E%2E/lib.tar.gz",
        "https://github.com/acme/project/raw/refs/heads/main/./lib.tar.gz",
        "https://github.com/acme/project/blob/main/lib.tar.gz",
    )
        @test source_of(url).location === nothing
    end
    @test GitHubSource("https://raw.githubusercontent.com/acme/project/raw/main/lib.tar.gz").location === nothing
    @test PA.download_url(source_of(raw), "Authorization" => "Bearer secret") == raw
    @test isempty(PA.download_headers("https://files.example.com/acme/project/contents/lib.tar.gz"))

    @test source_of("https://www.github.com/acme/project/releases/download/v1/lib.tar.gz").host == "github.com"
    @test source_of("https://www.github.com/acme/project/releases/download/v1/lib.tar.gz").location.tag == "v1"
    for host in ("evil.github.com", "evil.github.com:443", "a.localhost", "a.acme.ghe.com")
        @test PA.gh_renames(host)
    end
    for host in ("github.com", "acme.ghe.com", "ghe.example.com:8443", "github.com.example.com")
        @test !PA.gh_renames(host)
    end

    mktempdir() do directory
        archive = joinpath(directory, "archive")
        source = source_of(release_url("v1.0.0%2B2", "lib%2B1.tar.gz"))
        withenv("PATH" => "") do
            @test_throws "No token for github.com to download artifact `my_lib`. Set JULIA_PA_HOST_TOKEN_GITHUB_COM or JULIA_PA_ARTIFACT_TOKEN_MY_LIB, or install the GitHub CLI" PA.fetch_archive(source, archive, "my_lib")
        end
        if !Sys.iswindows()
            bin = joinpath(directory, "bin")
            mkdir(bin)
            # Downloads fail fast and offline through a proxy port that is closed.
            proxy = listen(Sockets.localhost, 0)
            proxy_port = getsockname(proxy)[2]
            close(proxy)
            withenv(
                "https_proxy" => "http://127.0.0.1:$proxy_port", "HTTPS_PROXY" => nothing, "all_proxy" => nothing, "ALL_PROXY" => nothing,
                "no_proxy" => nothing, "NO_PROXY" => nothing,
                "PATH" => "$bin:/usr/bin:/bin", "GH_HOST" => nothing,
                "GH_TOKEN" => "env", "GITHUB_TOKEN" => "env", "GH_ENTERPRISE_TOKEN" => "env", "GITHUB_ENTERPRISE_TOKEN" => "env",
            ) do
                # The asset is written to the path given with `--output=`.
                variables = ("GH_CONFIG_DIR", "GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN")
                log = fake_cli(bin, "gh", """
                    for argument in "\$@"; do
                        case "\$argument" in --output=*) printf data > "\${argument#--output=}";; esac
                    done
                    """; variables)
                PA.fetch_archive(source, archive, "my_lib")
                @test read(archive, String) == "data"
                # The token variables of gh reach it only for the host they are meant for.
                @test readlines(log) == [
                    "release", "download", "--repo=github.com/acme/project", "--pattern=lib+1.tar.gz",
                    "--output=$archive", "--", "v1.0.0+2", "", "env", "env", "", "",
                ]
                withenv("JULIA_PA_GH_CONFIG_DIR" => joinpath(directory, "gh")) do
                    PA.fetch_archive(source, archive, "my_lib")
                    @test readlines(log)[end-4] == joinpath(directory, "gh")
                end
                enterprise = source_of("https://ghe.example.com:8443/acme/project/releases/download/-v1/lib.tar.gz")
                PA.fetch_archive(enterprise, archive, "my_lib")
                @test readlines(log)[3:end] == ["--repo=ghe.example.com:8443/acme/project", "--pattern=lib.tar.gz", "--output=$archive", "--", "-v1", "", "", "", "", ""]
                withenv("GH_HOST" => "ghe.example.com:8443") do
                    PA.fetch_archive(enterprise, archive, "my_lib")
                    @test readlines(log)[end-3:end] == ["", "", "env", "env"]
                end

                # Raw file URLs are downloaded with `gh api`, which would expand
                # `{owner}` from the repository in the working directory.
                raw_source = source_of("https://github.com/acme/project/raw/refs/heads/main/dir/lib%20{owner}.tar.gz")
                log = fake_cli(bin, "gh", "printf data"; variables)
                PA.fetch_archive(raw_source, archive, "my_lib")
                @test read(archive, String) == "data"
                @test readlines(log) == [
                    "api", "--hostname=github.com", "--header=Accept: application/vnd.github.raw", "--",
                    "repos/acme/project/contents/dir/lib%20%7Bowner%7D.tar.gz?ref=refs/heads/main", "", "env", "env", "", "",
                ]
                fake_cli(bin, "gh", "echo '{\"message\": \"Not Found\"}'; echo 'gh: Not Found (HTTP 404)' >&2; exit 1")
                @test_throws "`gh api` failed for artifact `my_lib` from $(raw_source.url). GitHub answers 404 when the file does not exist or the GitHub CLI cannot read the repository. Check `gh auth status --hostname github.com`.\ngh: Not Found (HTTP 404)" PA.fetch_archive(raw_source, archive, "my_lib")
                @test !isfile(archive)

                # gh would answer for github.com, so it is not asked.
                rm(log)
                @test_throws "No token for evil.github.com" PA.fetch_archive(source_of("https://evil.github.com/acme/project/releases/download/v1/lib.tar.gz"), archive, "my_lib")
                @test !isfile(log)

                # A name that `--pattern` would read as a glob is not passed to it.
                @test !PA.gh_download("gh", source, source_of(release_url("v1", "lib[1].tar.gz")).location, archive, "my_lib")
                @test !isfile(log)

                # The error of a CLI that cannot start does not show the environment.
                write(joinpath(bin, "gh"), "#!/nonexistent/interpreter\n")
                message = withenv("SECRET_FOR_TEST" => "leaked-secret") do
                    try
                        PA.fetch_archive(source, archive, "my_lib")
                    catch
                        join((sprint(showerror, error.exception) for error in current_exceptions()), "\n")
                    end
                end
                @test occursin("`gh release download` failed", message) && occursin("Could not start gh", message)
                @test !occursin("leaked-secret", message)

                # Signed URLs in the error output of a CLI lose their query.
                fake_cli(bin, "gh", "echo 'Get \"https://objects.example.com/asset?X-Amz-Signature=SIGNATURE\": EOF' >&2; exit 1")
                @test_throws "Get \"https://objects.example.com/…\": EOF" PA.fetch_archive(source, archive, "my_lib")
                @test !occursin("SIGNATURE", try PA.fetch_archive(source, archive, "my_lib") catch err; sprint(showerror, err) end)

                # gh would log its requests including signed URLs.
                fake_cli(bin, "gh", "echo \"debug=\$GH_DEBUG\$DEBUG\" >&2; exit 1")
                withenv("GH_DEBUG" => "api", "DEBUG" => "1") do
                    @test_throws r"\ndebug=\z" PA.fetch_archive(source, archive, "my_lib")
                end

                fake_cli(bin, "gh", "echo 'release not found' >&2; exit 1")
                @test_throws "`gh release download` failed for artifact `my_lib` from $(source.url). The GitHub CLI reports a missing release when it cannot read the repository. Check `gh auth status --hostname github.com`.\nrelease not found" PA.fetch_archive(source, archive, "my_lib")

                # Other URLs are downloaded with the token of the GitHub CLI.
                other = GitHubSource("https://github.com/acme/project/archive/v1.tar.gz")
                unreachable = "while requesting $(other.url)"
                log = fake_cli(bin, "gh", "echo gh-token")
                @test_throws unreachable PA.fetch_archive(other, archive, "my_lib")
                @test readlines(log) == ["auth", "token", "--hostname", "github.com"]
                fake_cli(bin, "gh", "exit 1")
                @test_throws "The GitHub CLI has no token for github.com. Run `gh auth login --hostname github.com`" PA.fetch_archive(other, archive, "my_lib")

                # When a login is allowed, gh logs in before it is used.
                state = joinpath(directory, "gh-logged-in")
                log = fake_cli(bin, "gh", """
                    case "\$1 \$2" in
                        "auth token") [ -f '$state' ] && echo gh-token || exit 1;;
                        "auth login") sleep 1; touch '$state';;
                        "release download") for argument in "\$@"; do
                            case "\$argument" in --output=*) printf data > "\${argument#--output=}";; esac
                        done;;
                    esac
                    """; append = true)
                rm(log)
                PA.fetch_archive(source, archive, "my_lib")
                @test readlines(log)[1:2] == ["release", "download"]
                rm(log)
                login = (:info, "Artifact `my_lib` needs a GitHub CLI login to github.com. Running `gh auth login --hostname github.com`.")
                withenv("JULIA_PA_LOGIN" => "true") do
                    @test_logs login PA.fetch_archive(source, archive, "my_lib")
                    token_check = ["auth", "token", "--hostname", "github.com"]
                    @test readlines(log)[1:14] == [token_check; token_check; "auth"; "login"; "--hostname"; "github.com"; "release"; "download"]
                    rm(log)
                    PA.fetch_archive(source, archive, "my_lib")
                    @test readlines(log)[1:6] == ["auth", "token", "--hostname", "github.com", "release", "download"]
                    rm(log)
                    rm(state)
                    @test_logs login @test_throws unreachable PA.fetch_archive(other, archive, "my_lib")
                    @test readlines(log) == [token_check; token_check; "auth"; "login"; "--hostname"; "github.com"; token_check]
                    # A logged-in gh is asked for its token once.
                    rm(log)
                    @test_throws unreachable PA.fetch_archive(other, archive, "my_lib")
                    @test readlines(log) == token_check
                    # Logins run one at a time, so a second task finds the first login.
                    rm(log)
                    rm(state)
                    @test_logs login @sync for index in 1:2
                        @async PA.fetch_archive(source, joinpath(directory, "archive$index"), "my_lib")
                    end
                    @test count(==("login"), readlines(log)) == 1
                    # Only github.com and GHE.com hosts are logged in to. Another
                    # server could relay the device login of gh to github.com.
                    rm(log)
                    rm(state)
                    PA.fetch_archive(enterprise, archive, "my_lib")
                    @test readlines(log)[1:2] == ["release", "download"]
                    fake_cli(bin, "gh", "exit 1")
                    @test_logs login @test_throws "`gh auth login --hostname github.com` failed for artifact `my_lib`." PA.fetch_archive(source, archive, "my_lib")
                end

                # A token that is set bypasses the GitHub CLI.
                rm(log)
                withenv("JULIA_PA_HOST_TOKEN_GITHUB_COM" => "host-token") do
                    @test_throws unreachable PA.fetch_archive(other, archive, "my_lib")
                    @test !isfile(log)
                end
                withenv("JULIA_PA_ARTIFACT_TOKEN_MY_LIB" => "bad\ntoken") do
                    @test_throws "The token for github.com contains a control character" PA.fetch_archive(other, archive, "my_lib")
                end
            end
        end
    end
end
