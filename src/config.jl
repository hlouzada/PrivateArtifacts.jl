const ARTIFACT_TOKEN_ENV_PREFIX = "JULIA_PA_ARTIFACT_TOKEN_"
const HOST_TOKEN_ENV_PREFIX = "JULIA_PA_HOST_TOKEN_"
const GH_CONFIG_DIR_ENV = "JULIA_PA_GH_CONFIG_DIR"
const GLAB_CONFIG_DIR_ENV = "JULIA_PA_GLAB_CONFIG_DIR"
const AWS_CONFIG_DIR_ENV = "JULIA_PA_AWS_CONFIG_DIR"
const LOGIN_ENV = "JULIA_PA_LOGIN"

function env(name::AbstractString)::Union{String, Nothing}
    value = get(ENV, name, "")
    isempty(value) ? nothing : value
end

# Without a terminal, precompilation, `Pkg.build` and captured output would wait
# on a login prompt that nobody sees.
function login_allowed()::Bool
    value = env(LOGIN_ENV)
    value === nothing && return stdin isa Base.TTY && stdout isa Base.TTY && stderr isa Base.TTY
    allowed = Base.get_bool_env(LOGIN_ENV, false)
    allowed === nothing && error("$LOGIN_ENV must be true or false, got `$(escape_controls(value))`.")
    allowed
end

artifact_token_env(artifact::AbstractString)::String = ARTIFACT_TOKEN_ENV_PREFIX * uppercase(replace(artifact, r"[^A-Za-z0-9]" => "_"))

# Distinct hosts get distinct names. This relies on `url_authority` rejecting
# labels that start or end with `-`.
host_token_env(host::AbstractString)::String = HOST_TOKEN_ENV_PREFIX * uppercase(replace(host, "-" => "__", "." => "_", ":" => "___"))

function check_token(token::AbstractString, host::AbstractString)::Nothing
    (!isvalid(token) || contains(token, CONTROL)) && error("The token for $host contains a control character or invalid UTF-8.")
    nothing
end

normalize_host(value::AbstractString)::String = chopsuffix(lowercase(replace(value, r"^[A-Za-z]+://" => "", r"/.*"s => "")), ":443")

find_token(host::AbstractString, artifact::AbstractString)::Union{String, Nothing} = something(env(artifact_token_env(artifact)), env(host_token_env(host)), Some(nothing))
