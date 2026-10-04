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
