@testset "HTTP" begin
    mktempdir() do directory
        url = "https://files.example.invalid/lib.tar.gz"
        http = HTTPSource(url, PA.DEFAULT_HEADERS)
        @test_throws "No token for files.example.invalid to download artifact `my_lib`. Set JULIA_PA_HOST_TOKEN_FILES_EXAMPLE_INVALID or JULIA_PA_ARTIFACT_TOKEN_MY_LIB." PA.request_headers(http, "my_lib")
        withenv("JULIA_PA_HOST_TOKEN_FILES_EXAMPLE_INVALID" => "host-token") do
            @test PA.request_headers(http, "my_lib") == (["Authorization" => "Bearer host-token"], ["Authorization"])
            withenv("JULIA_PA_ARTIFACT_TOKEN_MY_LIB" => "artifact-token") do
                @test PA.request_headers(http, "my_lib")[1] == ["Authorization" => "Bearer artifact-token"]
            end
            custom = HTTPSource(url, ["Accept" => "*/*", "X-Api-Key" => "key={token}"])
            @test PA.request_headers(custom, "my_lib") == (["Accept" => "*/*", "X-Api-Key" => "key=host-token"], ["X-Api-Key"])
        end
        withenv("JULIA_PA_HOST_TOKEN_FILES_EXAMPLE_INVALID" => "bad\ntoken") do
            @test_throws "The token for files.example.invalid contains a control character" PA.request_headers(http, "my_lib")
        end
        # A CLI can print a NUL, which no environment variable can hold.
        @test_throws "The token for gitlab.example.com contains a control character" PA.check_token("bad\0token", "gitlab.example.com")
        @test_throws "invalid UTF-8" PA.check_token("bad\x9btoken", "gitlab.example.com")
        # Headers without `{token}` need no token.
        public = HTTPSource(url, ["Accept" => "*/*"])
        @test PA.request_headers(public, "my_lib") == (["Accept" => "*/*"], String[])
    end
end
