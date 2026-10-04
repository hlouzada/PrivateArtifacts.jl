@testset "entries" begin
    url = "https://files.example.com/lib.tar.gz"
    entry(settings...) = Dict{String, Any}("url" => url, "sha256" => "A"^64, settings...)
    parsed = PA.parse_source(entry(), "my_lib")
    @test (parsed.url, parsed.sha256) == (url, "a"^64)
    @test parsed.source isa HTTPSource
    @test (parsed.source.url, parsed.source.host, parsed.source.headers) == (url, "files.example.com", ("Authorization" => "Bearer {token}",))
    @test PA.parse_source(entry("kind" => "gitlab"), "my_lib").source isa GitLabSource
    @test source_of(url) == source_of(url)
    @test source_of(url; kind = "gitlab") == source_of(url; kind = "gitlab")
    headers = ["Accept" => "*/*"]
    unshared = HTTPSource(url, headers)
    push!(headers, "X-Api-Key" => "{token}")
    @test length(unshared.headers) == 1
    @test_throws "Not a plain https URL: ftp://files.example.com/lib.tar.gz" HTTPSource("ftp://files.example.com/lib.tar.gz", ())
    @test_throws ArgumentError GitLabSource("http://gitlab.example.com/lib.tar.gz", ())
    @test_throws ArgumentError GitHubSource("file:///lib.tar.gz")
    @test PA.parse_source(entry("kind" => "github"), "my_lib").source == GitHubSource(url)

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
        ("Accept" => "application/octet-stream", "X-Api-Key" => "{token}")
    @test isempty(source_of(url; headers = Dict()).headers)
    @test_throws "The `headers` of artifact `my_lib` must be a table of strings" source_of(url; headers = "X-Api-Key: {token}")
    @test_throws "Invalid header name `X Api` for artifact `my_lib`" source_of(url; headers = Dict("X Api" => "1"))
    @test_throws "The header `X-Api` of artifact `my_lib` must be a string without control characters" source_of(url; headers = Dict("X-Api" => "1\r\nX-Injected: yes"))
    @test_throws "must be a string without control characters" source_of(url; headers = Dict("X-Api" => 1))
    @test_throws "must be a string without control characters" source_of(url; headers = Dict("X-Api" => "\0{token}"))
    @test source_of(url; headers = Dict("X-Api" => "a\tb")).headers == ("X-Api" => "a\tb",)
    for name in ("Host", "host", "Transfer-Encoding", "Proxy-Authorization")
        @test_throws "Artifact `my_lib` must not set the header `$name`" source_of(url; headers = Dict(name => "x", "Authorization" => "Bearer {token}"))
    end
end
