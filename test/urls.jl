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
