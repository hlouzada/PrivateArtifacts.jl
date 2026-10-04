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
