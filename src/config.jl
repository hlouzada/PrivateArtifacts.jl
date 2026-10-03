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

# Matches C0 and C1 control characters. Bytes that are not valid UTF-8 never
# match, so callers check `isvalid` as well.
const CONTROL = r"[\x00-\x1f\x7f-\x9f]"

function check_token(token::AbstractString, host::AbstractString)::Nothing
    (!isvalid(token) || contains(token, CONTROL)) && error("The token for $host contains a control character or invalid UTF-8.")
    nothing
end

# A server or CLI must not drive the terminal through an error. `\u` escapes have
# four digits so that a following hex digit is not read as part of them.
function escape_controls(text::AbstractString)::String
    escaped(c) =
        !isvalid(c) ? join("\\x" * string(byte; base = 16, pad = 2) for byte in codeunits(string(c))) :
        c in ('\n', '\t') || !iscntrl(c) ? string(c) :
        "\\u" * string(UInt32(c); base = 16, pad = 4)
    join(escaped(c) for c in text)
end

normalize_host(value::AbstractString)::String = chopsuffix(lowercase(replace(value, r"^[A-Za-z]+://" => "", r"/.*"s => "")), ":443")

find_token(host::AbstractString, artifact::AbstractString)::Union{String, Nothing} = something(env(artifact_token_env(artifact)), env(host_token_env(host)), Some(nothing))

# `Sys.which` would also search the working directory. That directory may belong
# to the project being loaded.
function find_program(name::AbstractString)::Union{String, Nothing}
    file = Sys.iswindows() ? name * ".exe" : name
    for directory in split(get(ENV, "PATH", ""), Sys.iswindows() ? ';' : ':')
        path = joinpath(directory, file)
        isabspath(directory) && isfile(path) && Sys.isexecutable(path) && return path
    end
    nothing
end

# Signed download URLs keep their signature in the path or query, and a URL can
# hold a password.
function scrub(text::AbstractString)::String
    text = escape_controls(replace(text, "\r\n" => "\n"))
    text = replace(text, r"(?i)(https?://)[^\s\"/?#]*@" => s"\1")
    replace(text, r"(?i)(https?://[^\s\"/?#]*)[/?#][^\s\"]*" => s"\1/…")
end

# Base's error for a program that cannot start shows the environment of `command`
# including tokens. It is replaced here outside the `catch` so that it has no cause.
function spawn(command::Base.AbstractCmd, message::AbstractString, streams...)::Base.Process
    process = try
        run(command, streams...; wait = false)
    catch err
        err isa Base.IOError || rethrow()
        err
    end
    process isa Base.IOError &&
        error("$message\nCould not start $(basename(first(command.exec))): $(Base.struverror(process.code))")
    process
end

function run_cli(command::Base.AbstractCmd, message::AbstractString)::Tuple{Bool, String, String}
    output, errors = IOBuffer(), IOBuffer()
    process = spawn(command, message, devnull, output, errors)
    success(process), chomp(String(take!(output))), scrub(String(take!(errors)))
end

succeeds(command::Base.AbstractCmd, message::AbstractString)::Bool = success(spawn(command, message, devnull, devnull, devnull))

const LOGIN_LOCK = ReentrantLock()

# Logins share the terminal and run one at a time. `logged_in` is checked under
# the lock because another task may have logged in meanwhile.
login_once(logged_in::Function, login::Function)::Union{Bool, Nothing} = lock(() -> logged_in() || login(), LOGIN_LOCK)

function run_login(command::Base.AbstractCmd, shown_command::AbstractString, artifact::AbstractString, reason::AbstractString)::Nothing
    @info "Artifact `$artifact` $reason. Running `$shown_command`."
    message = "`$shown_command` failed for artifact `$artifact`."
    success(spawn(command, message, stdin, stdout, stderr)) || error(message)
    nothing
end

function cli_output(command::Base.AbstractCmd, message::AbstractString)::String
    succeeded, output, errors = run_cli(command, message)
    succeeded || error(rstrip("$message\n$errors"))
    output
end

# Streams standard output to `path`, since an archive need not fit in memory.
function cli_download(command::Base.AbstractCmd, path::AbstractString, message::AbstractString)::Nothing
    errors = IOBuffer()
    succeeded = open(file -> success(spawn(command, message, devnull, file, errors)), path, "w")
    succeeded && return
    rm(path; force = true)
    error(rstrip("$message\n$(scrub(String(take!(errors))))"))
end

function cli_value(command::Base.AbstractCmd, message::AbstractString)::String
    value = cli_output(command, message)
    isempty(value) && error(message)
    value
end

# `files` maps environment variables of the CLI to paths in the directory named
# by `variable`. An empty path names the directory itself.
function with_config_dir(command::Base.AbstractCmd, variable::AbstractString, files::AbstractVector{<:Pair{<:AbstractString,<:AbstractString}})::Base.AbstractCmd
    directory = env(variable)
    directory === nothing && return command
    directory = abspath(expanduser(directory))
    addenv(command, (name => (isempty(file) ? directory : joinpath(directory, file)) for (name, file) in files)...)
end

# These variables make gh and glab log their requests including signed URLs and
# login tokens.
without_debug(command::Base.AbstractCmd)::Base.AbstractCmd = addenv(command, "GH_DEBUG" => nothing, "DEBUG" => nothing, "GLAB_DEBUG_HTTP" => nothing)

# The tokens `names` are meant for `owner`. A CLI would otherwise send them to any
# host it is given.
without_tokens(command::Base.AbstractCmd, names::Tuple{Vararg{AbstractString}}, host::AbstractString, owner::AbstractString)::Base.AbstractCmd =
    host == owner ? command : addenv(command, (name => nothing for name in names)...)
