const GITLAB_COM = "gitlab.com"
const GLAB_TOKEN_ENVS = ("GITLAB_TOKEN", "GITLAB_ACCESS_TOKEN", "OAUTH_TOKEN")

const GitLabSource = HeaderSource{:gitlab}

# An empty `directory` keeps glab from reading the config of a repository.
glab_command(command::Base.AbstractCmd, directory::AbstractString)::Base.AbstractCmd =
    Cmd(without_debug(with_config_dir(command, GLAB_CONFIG_DIR_ENV, ["GLAB_CONFIG_DIR" => ""])); dir = directory)

function glab_stored_token(glab::AbstractString, host::AbstractString, directory::AbstractString)::@NamedTuple{token::Union{String, Nothing}, errors::String}
    message = "Checking the GitLab CLI login failed."
    default = run_cli(glab_command(`$glab config get host`, directory), message)
    default.succeeded || return (; token = nothing, default.errors)
    owner = normalize_host(isempty(default.output) ? GITLAB_COM : default.output)
    token_command(arguments) = without_tokens(glab_command(`$glab config get token $arguments`, directory), GLAB_TOKEN_ENVS, host, owner)
    stored = run_cli(token_command(`--host $host`), message)
    stored.succeeded && !isempty(stored.output) || return (; token = nothing, stored.errors)
    # glab returns the token of the default host for a host it has no token for.
    if host != owner && stored.output == run_cli(token_command(``), message).output
        return (; token = nothing, stored.errors)
    end
    (; token = stored.output, stored.errors)
end

glab_login(glab::AbstractString, directory::AbstractString, artifact::AbstractString)::Nothing = run_login(
    addenv(glab_command(`$glab auth login --hostname $GITLAB_COM`, directory), (name => nothing for name in GLAB_TOKEN_ENVS)...),
    "glab auth login --hostname $GITLAB_COM", artifact, "needs a GitLab CLI login to $GITLAB_COM",
)

function cli_token(source::GitLabSource, artifact::AbstractString)::String
    glab = find_program("glab")
    glab === nothing && no_token_error(
        source.host, artifact,
        ", or install the GitLab CLI (https://gitlab.com/gitlab-org/cli) and run `glab auth login --hostname $(source.host)`",
    )
    message = "The GitLab CLI has no token for $(source.host). Run `glab auth login --hostname $(source.host)`."
    mktempdir() do directory
        (; token, errors) = glab_stored_token(glab, source.host, directory)
        # A server that only claims to be GitLab could pass the login on to gitlab.com.
        if token === nothing && source.host == GITLAB_COM && login_allowed()
            login_once(
                () -> glab_stored_token(glab, source.host, directory).token !== nothing,
                () -> glab_login(glab, directory, artifact),
            )
            (; token, errors) = glab_stored_token(glab, source.host, directory)
        end
        token === nothing && error(rstrip("$message\n$errors"))
        token
    end
end
