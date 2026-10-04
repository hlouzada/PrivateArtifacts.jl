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
