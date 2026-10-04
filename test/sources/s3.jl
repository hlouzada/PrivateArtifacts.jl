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
