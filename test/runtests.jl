using Test
using Artifacts
using Downloads
using TOML
using Pkg
using Sockets
using PrivateArtifacts
using PrivateArtifacts: GitHubSource, GitLabSource, HTTPSource, S3Source

const PA = PrivateArtifacts

function write_artifacts_toml(directory, artifacts)
    path = joinpath(directory, "Artifacts.toml")
    open(io -> TOML.print(io, artifacts), path, "w")
    path
end

source_of(url; settings...) =
    PA.parse_source(Dict{String, Any}("url" => url, "sha256" => "0"^64, (String(k) => v for (k, v) in settings)...), "my_lib").source

# An executable `name` in `bin` that records its arguments and some environment
# variables in `bin/name.log` and then runs `body`. With `append` every call adds
# to the log.
function fake_cli(bin, name, body = ""; variables = (), append = false)
    log = joinpath(bin, "$name.log")
    recorded = join(("\"\$$variable\"" for variable in variables), " ")
    write(joinpath(bin, name), """
        #!/bin/sh
        printf '%s\\n' "\$@" $recorded $(append ? ">>" : ">") '$log'
        $body
        """)
    chmod(joinpath(bin, name), 0o755)
    log
end

# The configuration of the machine must not reach the tests, and a test run
# from a terminal must not ask for a login.
const AMBIENT = [
    [
        name => nothing for name in keys(ENV)
        if startswith(name, "JULIA_PA_") && name != "JULIA_PA_LOGIN" ||
            name in ("GH_CONFIG_DIR", "GLAB_CONFIG_DIR", "AWS_CONFIG_FILE", "AWS_SHARED_CREDENTIALS_FILE", "AWS_PROFILE") ||
            name in PA.AWS_CREDENTIAL_SOURCE_ENVS
    ];
    "JULIA_PA_LOGIN" => "false"
]

withenv(AMBIENT...) do
    @testset "environment" begin
        @test PA.artifact_token_env("my-lib.v2") == "JULIA_PA_ARTIFACT_TOKEN_MY_LIB_V2"
        @test PA.host_token_env("ghe.example.com:8443") == "JULIA_PA_HOST_TOKEN_GHE_EXAMPLE_COM___8443"
        @test PA.host_token_env("git-acme.com") == "JULIA_PA_HOST_TOKEN_GIT__ACME_COM"
        @test PA.host_token_env("git.acme.com") == "JULIA_PA_HOST_TOKEN_GIT_ACME_COM"
        @test PA.host_token_env("xn--bcher-kva.example") == "JULIA_PA_HOST_TOKEN_XN____BCHER__KVA_EXAMPLE"
        withenv("JULIA_PA_TEST" => "") do
            @test PA.env("JULIA_PA_TEST") === nothing
        end
        withenv("JULIA_PA_HOST_TOKEN_GIT_ACME_COM" => "acme-token") do
            @test PA.find_token("git.acme.com", "my-lib") == "acme-token"
            @test PA.find_token("git-acme.com", "my-lib") === nothing
        end
        @test PA.normalize_host("HTTPS://GitLab.Example.com:443/api") == "gitlab.example.com"
        @test PA.normalize_host("gitlab.example.com:8443") == "gitlab.example.com:8443"
        @test PA.normalize_host("") == ""

        @test PA.find_token("github.com", "my-lib") === nothing
        withenv("JULIA_PA_HOST_TOKEN_GITHUB_COM" => "host-token") do
            @test PA.find_token("github.com", "my-lib") == "host-token"
            @test PA.find_token("gitlab.com", "my-lib") === nothing
            withenv("JULIA_PA_ARTIFACT_TOKEN_MY_LIB" => "artifact-token") do
                @test PA.find_token("github.com", "my-lib") == "artifact-token"
                @test PA.find_token("gitlab.com", "my-lib") == "artifact-token"
                @test PA.find_token("github.com", "other") == "host-token"
            end
        end

        @test !PA.login_allowed()
        withenv("JULIA_PA_LOGIN" => nothing) do
            @test PA.login_allowed() == (stdin isa Base.TTY && stdout isa Base.TTY && stderr isa Base.TTY)
        end
        withenv("JULIA_PA_LOGIN" => "yes") do
            @test PA.login_allowed()
        end
        withenv("JULIA_PA_LOGIN" => "maybe") do
            @test_throws "JULIA_PA_LOGIN must be true or false, got `maybe`." PA.login_allowed()
        end

        if !Sys.iswindows()
            mktempdir() do directory
                cd(directory) do
                    write("fake-program", "#!/bin/sh\n")
                    chmod("fake-program", 0o755)
                    write("plain-file", "")
                    # Empty and relative entries would name the working directory.
                    withenv("PATH" => ":.:$directory/missing") do
                        @test PA.find_program("fake-program") === nothing
                    end
                    withenv("PATH" => "/nonexistent:$directory") do
                        @test PA.find_program("fake-program") == joinpath(directory, "fake-program")
                        @test PA.find_program("plain-file") === nothing
                    end
                end
            end
        end

        @test PA.scrub("see https://a.example.com/x?sig=1#f and HTTP://B.example.com/token=1/x\r\n") == "see https://a.example.com/… and HTTP://B.example.com/…\n"
        @test PA.scrub("at https://a.example.com: refused") == "at https://a.example.com: refused"
        @test PA.scrub("a\e[31mb\tc") == "a\\u001b[31mb\tc"
        @test PA.scrub("a\u009b31mb") == "a\\u009b31mb"
        @test PA.scrub("a\x9b2J") == "a\\x9b2J"
        @test PA.scrub("Get \"https://user:p@ss@h.example.com/x?sig=S\": EOF") == "Get \"https://h.example.com/…\": EOF"
        @test PA.scrub("x https://h.example.com/a\xe9?sig=S y") == "x https://h.example.com/… y"
        @test PA.scrub("remote https://user:SECRET@git.example.com/repo.git and xhttps://h.example.com/p?sig=1") ==
            "remote https://git.example.com/… and xhttps://h.example.com/…"

        files = ["AWS_CONFIG_FILE" => "config", "GH_CONFIG_DIR" => ""]
        command = `true`
        @test PA.with_config_dir(command, "JULIA_PA_TEST", files) === command
        withenv("JULIA_PA_TEST" => "/cli") do
            env = PA.with_config_dir(command, "JULIA_PA_TEST", files).env
            @test "AWS_CONFIG_FILE=$(joinpath(abspath("/cli"), "config"))" in env
            @test "GH_CONFIG_DIR=$(abspath("/cli"))" in env
        end
    end

    @testset "URLs and kinds" begin
        @test PA.url_authority("https://GitHub.com/acme/project") == "github.com"
        @test PA.url_authority("https://github.com?download=1") == "github.com"
        @test PA.url_authority("https://localhost:8443/file") == "localhost:8443"
        @test PA.url_authority("https://GitHub.com:443/file") == "github.com"
        @test PA.url_authority("https://github.com") == "github.com"
        @test PA.url_authority("https://github.com\n") === nothing
        @test PA.url_authority("http://github.com/file") === nothing
        @test PA.url_authority("https://github.com@example.com/file") === nothing
        @test PA.url_authority("https://github.com\\@example.com/file") === nothing
        for host in ("-a.example.com", "a-.example.com", "a..example.com", ".example.com", "example.com.")
            @test PA.url_authority("https://$host/file") === nothing
        end
        # U+0130 and U+212A lowercase to ASCII `i` and `k`.
        @test PA.url_authority("https://gİtlab.com/file") === nothing
        @test PA.url_authority("https://Kernel.example.com/file") === nothing

        @test PA.unescape("v1.0.0%2B2/caf%C3%A9 x") == "v1.0.0+2/café x"

        for (url, kind) in (
            "https://github.com/acme/project/releases/download/v1/lib.tar.gz" => "github",
            "https://api.github.com/repos/acme/project/releases/assets/1" => "github",
            "https://raw.githubusercontent.com/acme/project/main/lib.tar.gz" => "github",
            "https://acme.ghe.com/acme/project/releases/download/v1/lib.tar.gz" => "github",
            "https://api.acme.ghe.com/repos/acme/project/releases/assets/1" => "github",
            "https://ghe.example.com/acme/project/releases/download/v1/lib.tar.gz" => "github",
            "https://ghe.example.com/api/v3/repos/acme/project/releases/assets/1" => "github",
            "https://www.github.com/acme/project/releases/download/v1/lib.tar.gz" => "github",
            "https://gitlab.com/acme/project/-/package_files/1/download" => "gitlab",
            "https://gitlab.example.com/api/v4/projects/1/packages/generic/lib/1.0/lib.tar.gz" => "gitlab",
            "https://gitlab.example.com/acme/sub/project/-/releases/v1/downloads/lib.tar.gz" => "gitlab",
            "s3://my-bucket/lib.tar.gz" => "s3",
            "https://my-bucket.s3.eu-west-1.amazonaws.com/lib.tar.gz" => "s3",
            "https://my-bucket.s3.amazonaws.com/lib.tar.gz" => "s3",
            "https://s3.us-east-2.amazonaws.com/my-bucket/lib.tar.gz" => "s3",
            "https://my-bucket.s3.dualstack.us-east-1.amazonaws.com/lib.tar.gz" => "s3",
            "https://my-bucket.s3.cn-north-1.amazonaws.com.cn/lib.tar.gz" => "s3",
            "https://$("a"^32).r2.cloudflarestorage.com/my-bucket/lib.tar.gz" => "s3",
            "https://my-bucket.$("a"^32).eu.r2.cloudflarestorage.com/lib.tar.gz" => "s3",
            "https://account.r2.cloudflarestorage.com/my-bucket/lib.tar.gz" => "http",
            "https://files.example.com/lib.tar.gz" => "http",
            "https://files.example.com/acme/project/releases/download" => "http",
            "http://files.example.com/lib.tar.gz" => "http",
        )
            @test PA.infer_kind(url) == kind
        end
    end

    @testset "entries" begin
        url = "https://files.example.com/lib.tar.gz"
        entry(settings...) = Dict{String, Any}("url" => url, "sha256" => "A"^64, settings...)
        parsed = PA.parse_source(entry(), "my_lib")
        @test (parsed.url, parsed.sha256) == (url, "a"^64)
        @test parsed.source isa HTTPSource
        @test (parsed.source.url, parsed.source.host, parsed.source.headers) == (url, "files.example.com", ["Authorization" => "Bearer {token}"])
        @test PA.parse_source(entry("kind" => "gitlab"), "my_lib").source isa GitLabSource
        @test PA.parse_source(entry("kind" => "github"), "my_lib").source == GitHubSource(url, "files.example.com")

        context = "a `[[my_lib.download_private]]` entry"
        @test_throws "Expected $context to be a table, got `$url`" PA.parse_source(url, "my_lib")
        @test_throws "The `url` of $context contains a control character or invalid UTF-8: https://files.example.com/\\e]0;x\\a" PA.parse_source(entry("url" => "https://files.example.com/\e]0;x\a"), "my_lib")
        @test_throws "got `bad\\e`" PA.parse_source(entry("kind" => "bad\e"), "my_lib")
        @test_throws "contains a control character" PA.parse_source(entry("url" => "https://files.example.com/\u009b2J"), "my_lib")
        @test_throws "invalid UTF-8" PA.parse_source(entry("url" => "https://files.example.com/\x9b2J"), "my_lib")
        @test_throws "without control characters" source_of(url; headers = Dict("X-Api" => "a\x9bb"))
        @test_throws "Unknown key `\\e]0;x\\a`" PA.parse_source(entry("\e]0;x\a" => 1), "my_lib")
        @test_throws "Expected $context to have a string `url`" PA.parse_source(Dict("sha256" => "0"^64), "my_lib")
        @test_throws "Expected $context to have a `sha256` of 64 hexadecimal digits, got `nothing`" PA.parse_source(Dict("url" => url), "my_lib")
        @test_throws "got `$("0"^63)`" PA.parse_source(entry("sha256" => "0"^63), "my_lib")
        @test_throws "The `kind` of $context must be one of github, gitlab, http, s3, got `gitea`" PA.parse_source(entry("kind" => "gitea"), "my_lib")
        @test_throws "Unknown key `api` in a `[[my_lib.download_private]]` entry of kind `github`. It takes no other keys." PA.parse_source(
            entry("kind" => "github", "api" => "https://evil.example.com"), "my_lib",
        )
        @test_throws "Unknown key `region` in a `[[my_lib.download_private]]` entry of kind `http`. Allowed keys besides `url`, `sha256` and `kind`: headers." PA.parse_source(
            entry("region" => "eu-west-1"), "my_lib",
        )
        @test_throws "Unknown key `headers`" PA.parse_source(Dict("url" => "s3://my-bucket/lib", "sha256" => "0"^64, "headers" => Dict()), "my_lib")
        @test_throws "The URL of private artifact `my_lib` is not a plain https URL: http://files.example.com/lib.tar.gz" source_of(
            "http://files.example.com/lib.tar.gz",
        )
        @test_throws "not a plain https URL" source_of("http://files.example.com/lib.tar.gz"; kind = "gitlab")
        @test_throws "not a plain https URL" source_of("file:///lib.tar.gz"; kind = "github")

        @test source_of(url; headers = Dict("X-Api-Key" => "{token}", "Accept" => "application/octet-stream")).headers ==
            ["Accept" => "application/octet-stream", "X-Api-Key" => "{token}"]
        @test isempty(source_of(url; headers = Dict()).headers)
        @test_throws "The `headers` of artifact `my_lib` must be a table of strings" source_of(url; headers = "X-Api-Key: {token}")
        @test_throws "Invalid header name `X Api` for artifact `my_lib`" source_of(url; headers = Dict("X Api" => "1"))
        @test_throws "The header `X-Api` of artifact `my_lib` must be a string without control characters" source_of(url; headers = Dict("X-Api" => "1\r\nX-Injected: yes"))
        @test_throws "must be a string without control characters" source_of(url; headers = Dict("X-Api" => 1))
        @test_throws "must be a string without control characters" source_of(url; headers = Dict("X-Api" => "\0{token}"))
        @test source_of(url; headers = Dict("X-Api" => "a\tb")).headers == ["X-Api" => "a\tb"]
        for name in ("Host", "host", "Transfer-Encoding", "Proxy-Authorization")
            @test_throws "Artifact `my_lib` must not set the header `$name`" source_of(url; headers = Dict(name => "x", "Authorization" => "Bearer {token}"))
        end
    end

    @testset "redirects" begin
        server = listen(Sockets.localhost, 0)
        port = getsockname(server)[2]
        locations = Dict(
            "/to-other" => "http://localhost:$port/file", "/to-same" => "/file", "/loop" => "/loop",
            "/dir/rel" => "file", "/to-missing" => "/missing?signature=SECRET", "/to-space" => "/fi le/\u00e9.tar.gz",
            "/back" => "/hop?signature=SECRET", "/hop" => "/back", "/to-status" => "/status", "/to-json" => "/json",
        )
        requests = Dict{String, Vector{String}}()
        bounces = Ref(0)
        task = @async while true
            socket = try
                accept(server)
            catch
                break
            end
            lines = String[]
            while !isempty(begin line = readline(socket) end)
                push!(lines, line)
            end
            path = first(split(split(lines[1])[2], '?'))
            requests[path] = lines[2:end]
            # `/back` redirects to `/hop` and `/hop` back to `/back`. The second request
            # to `/back` fails.
            bounces[] += path == "/back"
            path == "/back" && bounces[] == 2 && (path = "/missing")
            write(socket,
                haskey(locations, path) ? "HTTP/1.1 302 Found\r\nLocation: $(locations[path])\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" :
                path == "/missing" ? "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" :
                path == "/status" ? "HTTP/1.1 404 x\e]0;pwned\a\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" :
                path == "/json" ? "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\n\e]0;" :
                "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\ndata")
            close(socket)
        end
        sent(path, name) = any(line -> startswith(lowercase(line), lowercase(name) * ":"), requests[path])
        mktempdir() do directory
            archive = joinpath(directory, "archive")
            headers = ["Accept" => "*/*", "X-Api-Key" => "secret"]
            base = "http://127.0.0.1:$port"
            withenv("no_proxy" => "*", "NO_PROXY" => "*") do
                PA.download_archive("$base/to-other", archive, headers, ["X-Api-Key"])
                @test read(archive, String) == "data"
                @test sent("/to-other", "X-Api-Key")
                @test !sent("/file", "X-Api-Key")
                @test sent("/file", "Accept")

                PA.download_archive("$base/to-same", archive, headers, ["X-Api-Key"])
                @test sent("/file", "X-Api-Key")

                PA.download_archive("$base/dir/rel", archive, headers, ["X-Api-Key"])
                @test haskey(requests, "/dir/file")

                @test_throws "Too many redirects from $base/loop" PA.download_archive("$base/loop", archive, headers, [])

                # libcurl would encode these characters when following the redirect itself.
                PA.download_archive("$base/to-space", archive, headers, [])
                @test haskey(requests, "/fi%20le/%C3%A9.tar.gz")

                errors = try
                    PA.download_archive("$base/to-missing", archive, headers, [])
                catch
                    [sprint(showerror, error.exception) for error in current_exceptions()]
                end
                @test occursin("Downloading $base/to-missing failed after a redirect", only(errors))
                @test occursin("404", only(errors)) && !occursin("SECRET", only(errors))
                @test_throws "Downloading $base/back failed after a redirect" PA.download_archive("$base/back", archive, headers, [])

                # The URL of the entry is not a secret.
                @test_throws "while requesting $base/missing?x=1" PA.download_archive("$base/missing?x=1", archive, headers, [])

                # A body that is not JSON is not shown, and libcurl follows only https redirects.
                @test_throws "GET $base/json did not return valid JSON." PA.get_json("$base/json", [])
                @test_throws r"Protocol \"?http\"? not supported|disabled" PA.get_json("$base/to-json", [])

                # A status line from the server cannot drive the terminal.
                for path in ("/status", "/to-status")
                    message = try
                        PA.download_archive("$base$path", archive, headers, [])
                    catch err
                        sprint(showerror, err)
                    end
                    @test occursin("404 x\\u001b]0;pwned\\u0007", message) && !occursin('\e', message)
                end

                # A global hook of Downloads, for example for client certificates, still applies.
                if isdefined(Downloads, :EASY_HOOK)
                    called = Ref(false)
                    previous = Downloads.EASY_HOOK[]
                    Downloads.EASY_HOOK[] = (easy, info) -> (called[] = true)
                    try
                        PA.download_archive("$base/file", archive, headers, [])
                    finally
                        Downloads.EASY_HOOK[] = previous
                    end
                    @test called[]
                end
            end
        end
        close(server)
        wait(task)

        # The API request and the download of a GitHub release share a connection.
        server = listen(Sockets.localhost, 0)
        port = getsockname(server)[2]
        connections = Ref(0)
        task = @async while true
            socket = try
                accept(server)
            catch
                break
            end
            connections[] += 1
            @async while true
                request_line = readline(socket)
                isempty(request_line) && break
                while !isempty(readline(socket)) end
                body = split(request_line)[2] == "/json" ? "{}" : "data"
                write(socket, "HTTP/1.1 200 OK\r\nContent-Length: $(sizeof(body))\r\n\r\n$body")
            end
        end
        mktempdir() do directory
            withenv("no_proxy" => "*", "NO_PROXY" => "*") do
                downloader = Downloads.Downloader()
                base = "http://127.0.0.1:$port"
                @test PA.get_json("$base/json", []; downloader) == Dict()
                PA.download_archive("$base/file", joinpath(directory, "archive"), [], []; downloader)
                @test read(joinpath(directory, "archive"), String) == "data"
                @test connections[] == 1
            end
        end
        close(server)
        wait(task)

        response(location) = Downloads.Response("https", "https://a.example.com/x", 302, "", ["location" => location])
        @test PA.redirect_target("https://a.example.com/x", response("https://b.example.com/y")) == "https://b.example.com/y"
        @test PA.redirect_target("https://a.example.com:8443/x", response("/y?z")) == "https://a.example.com:8443/y?z"
        @test PA.redirect_target("https://a.example.com/x", response("//b.example.com/y")) == "https://b.example.com/y"
        @test PA.redirect_target("https://a.example.com/d/x", response(" ../y#f ")) == "https://a.example.com/y"
        @test_throws "Refusing the redirect from https://a.example.com/… to http://b.example.com/…" PA.redirect_target(
            "https://a.example.com/x", response("http://b.example.com/y?signature=SECRET"),
        )
        @test_throws "Refusing the redirect" PA.redirect_target("https://a.example.com/x", response("file:///etc/passwd"))
        @test_throws "Refusing the redirect from https://a.example.com/… to https:…" PA.redirect_target("https://a.example.com/x", response("https:b.example.com/y"))
        @test PA.redirect_target("https://a.example.com/x", response("https://b.example.com/c/../d")) == "https://b.example.com/d"
        @test PA.redirect_target("https://a.example.com/x", response("//b.example.com/c/./d")) == "https://b.example.com/c/d"
        @test PA.origin("https://a.example.com:443/x") == PA.origin("https://A.example.com/y") != PA.origin("https://a.example.com:4443/x")
        @test PA.origin("http://a.example.com:80/x") == "http://a.example.com"
        @test PA.redirect_target("http://a.example.com/x", response("https://b.example.com/y")) == "https://b.example.com/y"
        @test_throws "has no valid `Location` header" PA.redirect_target("https://a.example.com/x", Downloads.Response("https", "", 302, "", []))
        @test PA.origin("HTTPS://A.example.com:8443/x?y") == "https://a.example.com:8443"
        @test PA.redact("https://a.example.com/token=SECRET/x?signature=SECRET") == "https://a.example.com/…"
        @test PA.redact("https://a\e[0m.example.com/x") == "https://a\\e[0m.example.com/…"
        @test PA.redact("not a URL") == "…"
        @test PA.redact("https://user:SECRET@a.example.com/x") == "https://a.example.com/…"
        @test PA.redact("https://user:p@ss@a.example.com/x") == "https://a.example.com/…"

        # Reference resolution examples of RFC 3986 without fragments.
        base = "http://a/b/c/d;p?q"
        for (reference, target) in (
            "g" => "http://a/b/c/g", "./g" => "http://a/b/c/g", "g/" => "http://a/b/c/g/", "/g" => "http://a/g",
            "//g" => "http://g", "?y" => "http://a/b/c/d;p?y", "g?y" => "http://a/b/c/g?y", "#s" => "http://a/b/c/d;p?q",
            "" => "http://a/b/c/d;p?q", "." => "http://a/b/c/", ".." => "http://a/b/", "../g" => "http://a/b/g",
            "../../g" => "http://a/g", "../../../g" => "http://a/g", "/./g" => "http://a/g", "g." => "http://a/b/c/g.",
            "./../g" => "http://a/b/g", "g/../h" => "http://a/b/c/h", "g?y/./x" => "http://a/b/c/g?y/./x",
        )
            @test PA.resolve_reference(base, reference) == target
        end
    end

    if !Sys.iswindows()
        @testset "HTTP" begin
            mktempdir() do directory
                url = "https://files.example.invalid/lib.tar.gz"
                http = HTTPSource(url, "files.example.invalid", PA.DEFAULT_HEADERS)
                @test_throws "No token for files.example.invalid to download artifact `my_lib`. Set JULIA_PA_HOST_TOKEN_FILES_EXAMPLE_INVALID or JULIA_PA_ARTIFACT_TOKEN_MY_LIB." PA.request_headers(http, "my_lib")
                withenv("JULIA_PA_HOST_TOKEN_FILES_EXAMPLE_INVALID" => "host-token") do
                    @test PA.request_headers(http, "my_lib") == (["Authorization" => "Bearer host-token"], ["Authorization"])
                    withenv("JULIA_PA_ARTIFACT_TOKEN_MY_LIB" => "artifact-token") do
                        @test PA.request_headers(http, "my_lib")[1] == ["Authorization" => "Bearer artifact-token"]
                    end
                    custom = HTTPSource(url, "files.example.invalid", ["Accept" => "*/*", "X-Api-Key" => "key={token}"])
                    @test PA.request_headers(custom, "my_lib") == (["Accept" => "*/*", "X-Api-Key" => "key=host-token"], ["X-Api-Key"])
                end
                withenv("JULIA_PA_HOST_TOKEN_FILES_EXAMPLE_INVALID" => "bad\ntoken") do
                    @test_throws "The token for files.example.invalid contains a control character" PA.request_headers(http, "my_lib")
                end
                # A CLI can print a NUL, which no environment variable can hold.
                @test_throws "The token for gitlab.example.com contains a control character" PA.check_token("bad\0token", "gitlab.example.com")
                @test_throws "invalid UTF-8" PA.check_token("bad\x9btoken", "gitlab.example.com")
                # Headers without `{token}` need no token.
                public = HTTPSource(url, "files.example.invalid", ["Accept" => "*/*"])
                @test PA.request_headers(public, "my_lib") == (["Accept" => "*/*"], String[])
            end
        end

        @testset "GitLab" begin
            mktempdir() do directory
                gitlab = GitLabSource("https://gitlab.example.com/api/v4/projects/1/packages/generic/lib/1/lib.tar.gz", "gitlab.example.com", PA.DEFAULT_HEADERS)
                withenv("PATH" => "") do
                    @test_throws "No token for gitlab.example.com to download artifact `my_lib`. Set JULIA_PA_HOST_TOKEN_GITLAB_EXAMPLE_COM or JULIA_PA_ARTIFACT_TOKEN_MY_LIB, or install the GitLab CLI" PA.request_headers(gitlab, "my_lib")
                end
                bin = joinpath(directory, "bin")
                mkdir(bin)
                # Like glab: `config get host` names its default host, and `config get token`
                # answers only for a host it has a login for. Token calls are logged.
                log = joinpath(bin, "glab.log")
                function fake_glab(token_body)
                    write(joinpath(bin, "glab"), """
                        #!/bin/sh
                        if [ "\$3" = host ]; then echo "\$FAKE_GLAB_HOST"; exit 0; fi
                        printf '%s\\n' "\$@" "\$PWD" "\$GLAB_CONFIG_DIR" "\$GITLAB_TOKEN" "\$GITLAB_ACCESS_TOKEN" "\$OAUTH_TOKEN" >> '$log'
                        $token_body
                        """)
                    chmod(joinpath(bin, "glab"), 0o755)
                end
                withenv(
                    "PATH" => "$bin:/usr/bin:/bin", "GITLAB_TOKEN" => "env-token", "GITLAB_ACCESS_TOKEN" => "env-token",
                    "OAUTH_TOKEN" => "env-token", "FAKE_GLAB_HOST" => nothing,
                ) do
                    fake_glab("[ \"\$4\" = --host ] && echo glab-token")
                    @test PA.request_headers(gitlab, "my_lib")[1] == ["Authorization" => "Bearer glab-token"]
                    calls = readlines(log)
                    # glab runs in an empty directory. Its token variables reach it only for
                    # its default host, which is gitlab.com here.
                    @test calls[1:5] == ["config", "get", "token", "--host", "gitlab.example.com"]
                    @test calls[6] != pwd() && !isdir(calls[6])
                    @test calls[7:10] == ["", "", "", ""]
                    @test calls[11:13] == ["config", "get", "token"]
                    rm(log)
                    # glab's default host comes from its variables, config or CI environment.
                    withenv("FAKE_GLAB_HOST" => "https://GitLab.example.com:443", "JULIA_PA_GLAB_CONFIG_DIR" => joinpath(directory, "glab")) do
                        PA.request_headers(gitlab, "my_lib")
                        @test readlines(log)[7:10] == [joinpath(directory, "glab"), "env-token", "env-token", "env-token"]
                    end
                    withenv("JULIA_PA_HOST_TOKEN_GITLAB_EXAMPLE_COM" => "host-token") do
                        rm(log)
                        @test PA.request_headers(gitlab, "my_lib")[1] == ["Authorization" => "Bearer host-token"]
                        @test !isfile(log)
                    end
                    # A token that glab also gives without a host is not meant for this one.
                    fake_glab("echo glab-token")
                    @test_throws "The GitLab CLI has no token for gitlab.example.com" PA.request_headers(gitlab, "my_lib")
                    withenv("FAKE_GLAB_HOST" => "gitlab.example.com") do
                        @test PA.request_headers(gitlab, "my_lib")[1] == ["Authorization" => "Bearer glab-token"]
                    end
                    fake_cli(bin, "glab", "echo 'no token found' >&2; exit 1")
                    @test_throws "The GitLab CLI has no token for gitlab.example.com. Run `glab auth login --hostname gitlab.example.com`.\nno token found" PA.request_headers(gitlab, "my_lib")
                    fake_cli(bin, "glab", "echo")
                    @test_throws "The GitLab CLI has no token" PA.request_headers(gitlab, "my_lib")

                    # When a login is allowed, glab logs in to gitlab.com before it is used.
                    state = joinpath(directory, "glab-logged-in")
                    log = joinpath(bin, "glab.log")
                    write(joinpath(bin, "glab"), """
                        #!/bin/sh
                        echo "\$* \$GITLAB_TOKEN\$GLAB_DEBUG_HTTP" >> '$log'
                        case "\$1 \$2 \$3" in
                            "config get host") echo "\$FAKE_GLAB_HOST";;
                            "config get token") [ "\$4" = --host ] && [ -f '$state' ] && echo glab-token || exit 1;;
                            "auth login --hostname") sleep 1; touch '$state';;
                        esac
                        """)
                    rm(log; force = true)
                    gitlab_com = source_of("https://gitlab.com/acme/project/-/package_files/1/download")
                    @test_throws "The GitLab CLI has no token for gitlab.com. Run `glab auth login --hostname gitlab.com`." PA.request_headers(gitlab_com, "my_lib")
                    @test !any(startswith("auth"), readlines(log))
                    login = (:info, "Artifact `my_lib` needs a GitLab CLI login to gitlab.com. Running `glab auth login --hostname gitlab.com`.")
                    # glab would log the tokens of the login.
                    withenv("JULIA_PA_LOGIN" => "true", "GLAB_DEBUG_HTTP" => "true") do
                        rm(log)
                        @test (@test_logs login PA.request_headers(gitlab_com, "my_lib"))[1] == ["Authorization" => "Bearer glab-token"]
                        token_check = ["config get host env-token", "config get token --host gitlab.com env-token"]
                        @test readlines(log) == [token_check; token_check; "auth login --hostname gitlab.com "; token_check]
                        # A logged-in glab is asked for its token once.
                        rm(log)
                        PA.request_headers(gitlab_com, "my_lib")
                        @test readlines(log) == token_check
                        # Logins run one at a time, so a second task finds the first login.
                        rm(log)
                        rm(state)
                        @test_logs login @sync for _ in 1:2
                            @async PA.request_headers(gitlab_com, "my_lib")
                        end
                        @test count(startswith("auth login"), readlines(log)) == 1
                        # Only gitlab.com is logged in to. Another server could relay
                        # the login to gitlab.com.
                        rm(log)
                        rm(state)
                        withenv("FAKE_GLAB_HOST" => "gitlab.example.com") do
                            @test_throws "The GitLab CLI has no token for gitlab.example.com" PA.request_headers(gitlab, "my_lib")
                            @test !any(startswith("auth"), readlines(log))
                            # The token variables of glab are meant for its default host,
                            # so they do not reach the login to another one.
                            @test_logs login PA.request_headers(gitlab_com, "my_lib")
                            @test "auth login --hostname gitlab.com " in readlines(log)
                        end
                        rm(state)
                        fake_cli(bin, "glab", "exit 1")
                        @test_logs login @test_throws "`glab auth login --hostname gitlab.com` failed for artifact `my_lib`." PA.request_headers(gitlab_com, "my_lib")
                    end
                end
            end
        end
    end

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
        @test PA.parse_release_url(source_of(release_url("release/v1.0.0+2", "lib.tar.gz"))) ==
            (owner = "acme", repository = "project", tag = "release/v1.0.0+2", file = "lib.tar.gz")
        @test PA.parse_release_url(source_of("https://GHE.example.com:8443/acme/project/releases/download/v1/lib.tar.gz")).owner == "acme"
        @test PA.parse_release_url(GitHubSource(release_url("v1", "lib.tar.gz"), "ghe.example.com")) === nothing
        @test PA.parse_release_url(source_of("https://github.com/acme/project?x/releases/download/v1/lib.tar.gz"; kind = "github")) === nothing
        @test PA.parse_release_url(source_of("https://api.github.com/repos/acme/project/releases/assets/1")) === nothing
        @test PA.parse_release_url(source_of("https://github.com/acme/project/archive/refs/tags/v1.0.0.tar.gz")) === nothing
        @test PA.parse_release_url(GitHubSource(release_url("v1", "lib.tar.gz\n"), "github.com")) === nothing

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

        @test source_of("https://www.github.com/acme/project/releases/download/v1/lib.tar.gz").host == "github.com"
        @test PA.parse_release_url(source_of("https://www.github.com/acme/project/releases/download/v1/lib.tar.gz")).tag == "v1"
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
                withenv(
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

                    # gh would answer for github.com, so it is not asked.
                    rm(log)
                    @test_throws "No token for evil.github.com" PA.fetch_archive(source_of("https://evil.github.com/acme/project/releases/download/v1/lib.tar.gz"), archive, "my_lib")
                    @test !isfile(log)

                    # A name that `--pattern` would read as a glob is not passed to it.
                    @test !PA.gh_release_download("gh", source, PA.parse_release_url(source_of(release_url("v1", "lib[1].tar.gz"))), archive, "my_lib")
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
                    local_file = joinpath(directory, "local.tar.gz")
                    write(local_file, "local")
                    other = GitHubSource("file://$local_file", "github.com")
                    log = fake_cli(bin, "gh", "echo gh-token")
                    PA.fetch_archive(other, archive, "my_lib")
                    @test read(archive, String) == "local"
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
                        @test_logs login PA.fetch_archive(other, archive, "my_lib")
                        @test readlines(log) == [token_check; token_check; "auth"; "login"; "--hostname"; "github.com"; token_check]
                        # A logged-in gh is asked for its token once.
                        rm(log)
                        PA.fetch_archive(other, archive, "my_lib")
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
                        PA.fetch_archive(other, archive, "my_lib")
                        @test !isfile(log)
                    end
                    withenv("JULIA_PA_ARTIFACT_TOKEN_MY_LIB" => "bad\ntoken") do
                        @test_throws "The token for github.com contains a control character" PA.fetch_archive(other, archive, "my_lib")
                    end
                end
            end
        end
    end

    @testset "S3" begin
        aws(bucket, region) = (; bucket, region, endpoint = nothing)
        @test PA.s3_endpoint("a.s3.s3.amazonaws.com") == aws("a.s3", nothing)
        @test PA.s3_endpoint("bucket.s3.us-gov-west-1.amazonaws.com") == aws("bucket", "us-gov-west-1")
        @test PA.s3_endpoint("bucket.s3-us-west-2.amazonaws.com") == aws("bucket", "us-west-2")
        @test PA.s3_endpoint("bucket.s3.dualstack.us-east-1.amazonaws.com") == aws("bucket", "us-east-1")
        @test PA.s3_endpoint("bucket.s3.cn-north-1.amazonaws.com.cn") == aws("bucket", "cn-north-1")
        @test PA.s3_endpoint("bucket.s3-fips.us-east-1.amazonaws.com") == aws("bucket", "us-east-1")
        @test PA.s3_endpoint("bucket.s3-external-1.amazonaws.com") == aws("bucket", "us-east-1")
        @test PA.s3_endpoint("s3-external-1.amazonaws.com") == aws(nothing, "us-east-1")
        for authority in ("bucket.s3-external-1.eu-west-1.amazonaws.com", "bucket.s3-external-1.amazonaws.com.cn", "bucket.s3-website-us-east-1.amazonaws.com")
            @test PA.s3_endpoint(authority) === nothing
        end
        @test PA.s3_endpoint("bucket.s3-accelerate.amazonaws.com") == aws("bucket", nothing)
        @test PA.s3_endpoint("bucket.s3.eusc-de-east-1.amazonaws.eu") == aws("bucket", "eusc-de-east-1")
        @test PA.s3_endpoint("s3.us-east-2.amazonaws.com") == aws(nothing, "us-east-2")
        @test PA.s3_endpoint("s3.amazonaws.com") == aws(nothing, nothing)
        account = "0123456789abcdef"^2
        @test PA.s3_endpoint("$account.r2.cloudflarestorage.com") == (bucket = nothing, region = nothing, endpoint = "https://$account.r2.cloudflarestorage.com")
        @test PA.s3_endpoint("bucket.$account.eu.r2.cloudflarestorage.com") == (bucket = "bucket", region = nothing, endpoint = "https://$account.eu.r2.cloudflarestorage.com")
        for authority in ("files.example.com", "bucket.s3.fips.amazonaws.com", "ab.s3.amazonaws.com", "bucket.s3.amazonaws.com:443", "account.r2.cloudflarestorage.com")
            @test PA.s3_endpoint(authority) === nothing
        end

        virtual = "https://my-bucket.s3.eu-west-1.amazonaws.com"
        @test source_of("$virtual/v1/lib%2B1%20x.tar.gz") == S3Source("s3://my-bucket/v1/lib+1 x.tar.gz", "eu-west-1", nothing)
        @test source_of("https://my.bucket.s3.amazonaws.com/caf%C3%A9.tar.gz") == S3Source("s3://my.bucket/café.tar.gz", nothing, nothing)
        @test source_of("https://my.bucket.s3.amazonaws.com/lib.tar.gz"; region = "us-west-2").region == "us-west-2"
        @test source_of("$virtual/lib.tar.gz"; region = "eu-west-1").region == "eu-west-1"
        @test_throws "The `region` of artifact `my_lib` is `us-west-2`, but its URL names the region `eu-west-1`" source_of("$virtual/lib.tar.gz"; region = "us-west-2")
        @test_throws "The `region` of artifact `my_lib` must be an AWS region name, got `eu west`" source_of("$virtual/lib.tar.gz"; region = "eu west")
        # A virtual-hosted URL keeps any further bucket name in the key.
        @test source_of("$virtual/other-bucket/lib.tar.gz").uri == "s3://my-bucket/other-bucket/lib.tar.gz"
        @test source_of("https://s3.us-east-2.amazonaws.com/my-bucket/v1/lib.tar.gz") == S3Source("s3://my-bucket/v1/lib.tar.gz", "us-east-2", nothing)
        @test source_of("https://s3.amazonaws.com/my-bucket/lib.tar.gz") == S3Source("s3://my-bucket/lib.tar.gz", nothing, nothing)
        @test source_of("https://$account.r2.cloudflarestorage.com/my-bucket/lib.tar.gz") ==
            S3Source("s3://my-bucket/lib.tar.gz", nothing, "https://$account.r2.cloudflarestorage.com")
        @test source_of("https://my-bucket.$account.r2.cloudflarestorage.com/v1/lib.tar.gz") ==
            S3Source("s3://my-bucket/v1/lib.tar.gz", nothing, "https://$account.r2.cloudflarestorage.com")
        @test source_of("https://minio.example.com:9000/my-bucket/lib.tar.gz"; kind = "s3", region = "us-east-1") ==
            S3Source("s3://my-bucket/lib.tar.gz", "us-east-1", "https://minio.example.com:9000")
        @test source_of("s3://My_Bucket/v1/lib+1 x.tar.gz") == S3Source("s3://My_Bucket/v1/lib+1 x.tar.gz", nothing, nothing)
        @test source_of("s3://my-bucket/lib.tar.gz"; host = "MinIO.example.com:9000", region = "us-east-1") ==
            S3Source("s3://my-bucket/lib.tar.gz", "us-east-1", "https://minio.example.com:9000")

        @test source_of("s3://my-bucket/lib.tar.gz"; host = "minio.example.com:443").endpoint == "https://minio.example.com"
        for host in ("https://minio.example.com", "minio.example.com/bucket", "user@minio.example.com", "minio..example.com", "-minio.example.com", "minio.example.com:", "", 9000)
            @test_throws "The `host` of artifact `my_lib` must be a host name with an optional port, such as `minio.example.com:9000`, got `$host`" source_of(
                "s3://my-bucket/lib.tar.gz"; host,
            )
        end
        @test_throws "The `host` of artifact `my_lib` applies only to an `s3://` URL. An https URL names its host itself." source_of("$virtual/lib.tar.gz"; host = "minio.example.com")
        @test_throws "Unknown key `endpoint` in a `[[my_lib.download_private]]` entry of kind `s3`. Allowed keys besides `url`, `sha256` and `kind`: host, region." source_of(
            "s3://my-bucket/lib.tar.gz"; endpoint = "https://minio.example.com",
        )
        @test_throws "Expected an S3 URI `s3://<bucket>/<key>` for artifact `my_lib`, got s3://my-bucket" source_of("s3://my-bucket")
        @test_throws "Invalid S3 bucket `` in s3:///lib.tar.gz" source_of("s3:///lib.tar.gz")
        @test_throws "Invalid S3 bucket `ab`" source_of("s3://ab/lib.tar.gz")
        @test_throws "names no object" source_of("s3://my-bucket/")
        @test_throws "names no object" source_of("$virtual/")
        @test_throws "Expected an S3 object URL without query or fragment" source_of("$virtual")
        @test_throws "names no object" source_of("https://s3.amazonaws.com/my-bucket")
        @test_throws "Write `+` as `%2B`" source_of("$virtual/lib+1.tar.gz")
        for path in ("lib%2", "lib%zz", "a% 1b", "a b", "café")
            @test_throws "has a character that must be percent-encoded, or an invalid percent-encoding" source_of("$virtual/$path")
        end
        @test_throws "does not decode to valid UTF-8" source_of("$virtual/lib%FF")
        @test_throws "Expected an S3 object URL without query or fragment for artifact `my_lib`" source_of("$virtual/lib.tar.gz?versionId=1")

        mktempdir() do directory
            archive = joinpath(directory, "archive")
            source = source_of("$virtual/v1/lib.tar.gz")
            withenv("PATH" => "") do
                @test_throws "Artifact `my_lib` is at s3://my-bucket/v1/lib.tar.gz, which needs the AWS CLI" PA.fetch_archive(source, archive, "my_lib")
            end
            if !Sys.iswindows()
                bin = joinpath(directory, "bin")
                mkdir(bin)
                withenv("PATH" => "$bin:/usr/bin:/bin", "AWS_CLI_AUTO_PROMPT" => "on") do
                    log = fake_cli(bin, "aws", "printf data > \"\$4\""; variables = ("AWS_CLI_AUTO_PROMPT", "AWS_CONFIG_FILE", "AWS_SHARED_CREDENTIALS_FILE"))
                    PA.fetch_archive(source, archive, "my_lib")
                    @test read(archive, String) == "data"
                    @test readlines(log) == ["s3", "cp", "s3://my-bucket/v1/lib.tar.gz", archive, "--only-show-errors", "--region=eu-west-1", "off", "", ""]
                    minio = source_of("s3://my-bucket/lib.tar.gz"; host = "minio.example.com:9000")
                    withenv("JULIA_PA_AWS_CONFIG_DIR" => joinpath(directory, "aws")) do
                        PA.fetch_archive(minio, archive, "my_lib")
                    end
                    @test readlines(log) == [
                        "s3", "cp", "s3://my-bucket/lib.tar.gz", archive, "--only-show-errors", "--endpoint-url=https://minio.example.com:9000",
                        "off", joinpath(directory, "aws", "config"), joinpath(directory, "aws", "credentials"),
                    ]
                    fake_cli(bin, "aws", "echo 'Unable to locate credentials' >&2; exit 255")
                    @test_throws "`aws s3 cp` failed for artifact `my_lib` from s3://my-bucket/v1/lib.tar.gz.\nUnable to locate credentials" PA.fetch_archive(source, archive, "my_lib")

                    # When a login is allowed and the CLI has no credentials, it
                    # logs in the way the profile is set up and copies again.
                    state = joinpath(directory, "aws-logged-in")
                    log = fake_cli(bin, "aws", """
                        case "\$1 \$2" in
                            "--version ") echo "aws-cli/\${FAKE_AWS_VERSION:-2.15.0} Python/3.12.6 Linux/6.6 exe/x86_64";;
                            "s3 cp") [ -f '$state' ] && printf data > "\$4" && exit 0; echo 'Unable to locate credentials' >&2; exit 255;;
                            "configure export-credentials") [ -f '$state' ] || exit 255;;
                            "configure get") [ "\$3" = "\$FAKE_AWS_SETTING" ] && echo value || exit 1;;
                            "configure "|"sso login"|"login ") touch '$state';;
                        esac
                        """; append = true)
                    copy_call = ["s3", "cp", "s3://my-bucket/v1/lib.tar.gz", archive, "--only-show-errors", "--region=eu-west-1"]
                    check = ["configure", "export-credentials"]
                    version = ["--version"]
                    read_setting(key) = ["configure", "get", key]
                    all_settings = mapreduce(read_setting, vcat, ["sso_session", "sso_start_url", "login_session", "role_arn", "credential_process", "credential_source", "web_identity_token_file"])
                    rm(log)
                    @test_throws "Unable to locate credentials" PA.fetch_archive(source, archive, "my_lib")
                    @test readlines(log) == copy_call
                    withenv("JULIA_PA_LOGIN" => "true") do
                        for (setting, login, gets) in (
                                (nothing, ["configure"], all_settings),
                                ("sso_session", ["sso", "login"], read_setting("sso_session")),
                                ("sso_start_url", ["sso", "login"], [read_setting("sso_session"); read_setting("sso_start_url")]),
                                ("login_session", ["login"], [read_setting("sso_session"); read_setting("sso_start_url"); read_setting("login_session")]),
                            )
                            rm(log)
                            rm(state; force = true)
                            withenv("FAKE_AWS_SETTING" => setting) do
                                @test_logs (:info, "Artifact `my_lib` needs AWS CLI credentials. Running `aws $(join(login, " "))`.") PA.fetch_archive(source, archive, "my_lib")
                            end
                            @test readlines(log) == [copy_call; version; check; check; gets; login; copy_call]
                            @test read(archive, String) == "data"
                        end
                        # A profile that takes its credentials from elsewhere is not
                        # given access keys.
                        rm(log)
                        rm(state)
                        withenv("FAKE_AWS_SETTING" => "role_arn") do
                            @test_throws "The AWS CLI has no credentials for artifact `my_lib`, and its profile sets `role_arn`." PA.fetch_archive(source, archive, "my_lib")
                        end
                        @test readlines(log) == [copy_call; version; check; check; all_settings[1:12]]
                        withenv("AWS_CONTAINER_CREDENTIALS_FULL_URI" => "http://169.254.170.23/v1/credentials") do
                            @test_throws "The AWS CLI has no credentials for artifact `my_lib`, and `AWS_CONTAINER_CREDENTIALS_FULL_URI` is set." PA.fetch_archive(source, archive, "my_lib")
                        end
                        @test !isfile(state)
                        # Without `export-credentials`, any failure would look like
                        # missing credentials.
                        for old in ("2.8.9", "1.29.0")
                            rm(log)
                            withenv("FAKE_AWS_VERSION" => old) do
                                @test_throws "Unable to locate credentials" PA.fetch_archive(source, archive, "my_lib")
                            end
                            @test readlines(log) == [copy_call; version]
                        end
                        # With credentials, a failed copy is not a login problem.
                        fake_cli(bin, "aws", "[ \"\$1\" = s3 ] && echo 'Access Denied' >&2 && exit 1; echo aws-cli/2.9.0; exit 0"; append = true)
                        rm(log)
                        @test_throws "`aws s3 cp` failed for artifact `my_lib` from s3://my-bucket/v1/lib.tar.gz.\nAccess Denied" PA.fetch_archive(source, archive, "my_lib")
                        @test readlines(log) == [copy_call; version; check]
                        fake_cli(bin, "aws", "[ \"\$1\" = --version ] && echo aws-cli/2.9.0 && exit 0; exit 1")
                        @test_logs (:info, "Artifact `my_lib` needs AWS CLI credentials. Running `aws configure`.") @test_throws "`aws configure` failed for artifact `my_lib`." PA.fetch_archive(source, archive, "my_lib")
                    end
                end
            end
        end
    end

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
end
