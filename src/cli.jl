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

function run_cli(command::Base.AbstractCmd, message::AbstractString)::@NamedTuple{succeeded::Bool, output::String, errors::String}
    output, errors = IOBuffer(), IOBuffer()
    process = spawn(command, message, devnull, output, errors)
    (; succeeded = success(process), output = chomp(String(take!(output))), errors = scrub(String(take!(errors))))
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
    (; succeeded, output, errors) = run_cli(command, message)
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
