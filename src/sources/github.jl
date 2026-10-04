const GITHUB_COM = "github.com"

# `tag` and `file` stay percent-encoded.
struct ReleaseURL
    owner::String
    repository::String
    tag::String
    file::String
end

# `ref` and `path` stay percent-encoded.
struct RawURL
    owner::String
    repository::String
    ref::String
    path::String
end

# `host` is the web host even for an API URL. `location` is `nothing` for API
# and raw content hosts, which map to the same `host`, and for other URLs.
struct GitHubSource <: Source
    url::String
    host::String
    location::Union{ReleaseURL, RawURL, Nothing}
    function GitHubSource(url)
        authority = https_host(url)
        host = something(github_host(authority), authority)
        web = authority in (host, "www.github.com")
        new(url, host, web ? something(release_location(url), raw_location(url), Some(nothing)) : nothing)
    end
end

function github_host(authority::AbstractString)::Union{String, Nothing}
    authority in (GITHUB_COM, "www.github.com", "api.github.com", "raw.githubusercontent.com") && return GITHUB_COM
    m = match(r"^(?:api\.)?([a-z0-9-]+\.ghe\.com)\z", authority)
    m === nothing ? nothing : m[1]
end

function github_source(url::AbstractString, settings::AbstractDict, artifact::AbstractString)::GitHubSource
    check_settings(settings, (), "github", artifact)
    GitHubSource(url)
end

api_url(host::AbstractString)::String =
    host == GITHUB_COM ? "https://api.github.com" :
    endswith(host, ".ghe.com") ? "https://api.$host" :
    "https://$host/api/v3"

download_headers(url::AbstractString)::Vector{Pair{String, String}} =
    endswith(url, r"/releases/assets/[0-9]+") ? ["Accept" => "application/octet-stream"] :
    # Without this media type the contents API returns the file as base64 in JSON.
    contains(url, r"^https://[^/?#]+(?:/api/v3)?/repos/[^/?#]+/[^/?#]+/contents/") ? ["Accept" => "application/vnd.github.raw"] :
    Pair{String, String}[]

function release_location(url::AbstractString)::Union{ReleaseURL, Nothing}
    # A tag may contain `/`.
    m = match(r"^https://[^/]+/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/releases/download/(.+)/([^/?#\s]+)\z", url)
    m === nothing ? nothing : ReleaseURL(m.captures...)
end

# The web host answers 404 to API tokens for a raw file of a private repository.
# A ref is one segment, or `refs/heads/NAME` or `refs/tags/NAME`, since a longer
# ref cannot be told apart from the path.
function raw_location(url::AbstractString)::Union{RawURL, Nothing}
    m = match(r"^https://[^/]+/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/raw/((?:refs/(?:heads|tags)/)?[^/?#]+)/((?:[^/?#]+/)*[^/?#]+)\z", url)
    m === nothing && return nothing
    owner, repository, ref, path = m.captures
    any(segment -> unescape(segment) in (".", ".."), split("$ref/$path", '/')) && return nothing
    RawURL(owner, repository, ref, path)
end

# `+`, `&` and `=` would change the meaning of a query, and `gh api` expands
# `{owner}`, `{repo}` and `{branch}` from the repository in its working directory.
encode_endpoint_part(value::AbstractString)::String = percent_encode(value, r"[^A-Za-z0-9._~%/-]")

contents_endpoint(raw::RawURL)::String =
    "repos/$(raw.owner)/$(raw.repository)/contents/$(encode_endpoint_part(raw.path))?ref=$(encode_endpoint_part(raw.ref))"

download_url(source::GitHubSource, auth::Pair{String, String}; downloader::Downloads.Downloader = Downloads.Downloader())::String =
    download_url(source, source.location, auth; downloader)

download_url(source::GitHubSource, ::Nothing, auth::Pair{String, String}; downloader::Downloads.Downloader)::String = source.url

download_url(source::GitHubSource, raw::RawURL, auth::Pair{String, String}; downloader::Downloads.Downloader)::String =
    "$(api_url(source.host))/$(contents_endpoint(raw))"

function download_url(source::GitHubSource, release::ReleaseURL, auth::Pair{String, String}; downloader::Downloads.Downloader)::String
    (; owner, repository, tag, file) = release
    repository_url = "$(api_url(source.host))/repos/$owner/$repository"
    response = get_json("$repository_url/releases/tags/$tag", [auth, "Accept" => "application/vnd.github+json"]; downloader)
    "$repository_url/releases/assets/$(asset_id(response, file, source.url))"
end

function asset_id(release::AbstractDict, file::AbstractString, url::AbstractString)::Integer
    assets = release["assets"]
    index = findfirst(asset -> asset["name"] == unescape(file) || asset["browser_download_url"] == url, assets)
    index === nothing && error(
        "GitHub release `$(shown(release["tag_name"]))` has no asset `$file`. " *
        "Available assets: $(join((shown(asset["name"]) for asset in assets), ", ")).",
    )
    assets[index]["id"]::Integer
end

# Errors are built from the URL and the status code only. The server chooses the
# status line and the body, and these may hold control characters.
function get_json(url::AbstractString, headers::AbstractVector; downloader::Downloads.Downloader = Downloads.Downloader())::Any
    output = IOBuffer()
    # libcurl follows redirects here.
    response = with_curl_options(downloader, Downloads.Curl.CURLOPT_REDIR_PROTOCOLS => Downloads.Curl.CURLPROTO_HTTPS) do
        Downloads.request(url; headers, output, downloader, throw = false)
    end
    response isa Downloads.RequestError && error(escape_controls(sprint(showerror, response)))
    response.status == 200 || error(
        "GET $url failed with HTTP $(response.status). " *
        "GitHub answers 404 when the release does not exist or the token cannot read the repository.",
    )
    parsed = try
        JSON.parse(String(take!(output)))
    catch err
        err isa InterruptException && rethrow()
        err
    end
    parsed isa Exception && error("GET $url did not return valid JSON.")
    parsed
end

function gh_command(command::Base.AbstractCmd, host::AbstractString)::Base.AbstractCmd
    command = without_debug(with_config_dir(command, GH_CONFIG_DIR_ENV, ["GH_CONFIG_DIR" => ""]))
    command = without_tokens(command, ("GH_TOKEN", "GITHUB_TOKEN"), host, GITHUB_COM)
    without_tokens(command, ("GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"), host, normalize_host(get(ENV, "GH_HOST", "")))
end

# `gh` treats these hosts as another host and would hand out that host's token.
function gh_renames(host::AbstractString)::Bool
    name = first(split(host, ':'))
    endswith(name, ".github.com") || endswith(name, ".localhost") || (endswith(name, ".ghe.com") && github_host(name) != name)
end

function gh_stored_token(gh::AbstractString, host::AbstractString)::Union{String, Nothing}
    succeeded, token, _ = run_cli(gh_command(`$gh auth token --hostname $host`, host), "Checking the GitHub CLI login failed.")
    succeeded && !isempty(token) ? token : nothing
end

gh_login(gh::AbstractString, host::AbstractString, artifact::AbstractString)::Nothing = run_login(
    gh_command(`$gh auth login --hostname $host`, host), "gh auth login --hostname $host",
    artifact, "needs a GitHub CLI login to $host",
)

function gh_token(gh::AbstractString, host::AbstractString)::String
    message = "The GitHub CLI has no token for $host. Run `gh auth login --hostname $host`."
    cli_value(gh_command(`$gh auth token --hostname $host`, host), message)
end

# `true` when gh has written the archive.
gh_download(gh::AbstractString, source::GitHubSource, ::Nothing, archive::AbstractString, artifact::AbstractString)::Bool = false

# `false` for a name that `--pattern` would read as a glob.
function gh_download(gh::AbstractString, source::GitHubSource, release::ReleaseURL, archive::AbstractString, artifact::AbstractString)::Bool
    tag, file = unescape(release.tag), unescape(release.file)
    isvalid(tag) && isvalid(file) && !contains(file, r"[*?\[\]\\]") || return false
    repository = "$(source.host)/$(release.owner)/$(release.repository)"
    command = gh_command(`$gh release download --repo=$repository --pattern=$file --output=$archive -- $tag`, source.host)
    cli_output(
        command,
        "`gh release download` failed for artifact `$artifact` from $(source.url). " *
        "The GitHub CLI reports a missing release when it cannot read the repository. " *
        "Check `gh auth status --hostname $(source.host)`.",
    )
    true
end

function gh_download(gh::AbstractString, source::GitHubSource, raw::RawURL, archive::AbstractString, artifact::AbstractString)::Bool
    accept = "Accept: application/vnd.github.raw"
    command = gh_command(`$gh api --hostname=$(source.host) --header=$accept -- $(contents_endpoint(raw))`, source.host)
    cli_download(
        command, archive,
        "`gh api` failed for artifact `$artifact` from $(source.url). " *
        "GitHub answers 404 when the file does not exist or the GitHub CLI cannot read the repository. " *
        "Check `gh auth status --hostname $(source.host)`.",
    )
    true
end

function token_download(source::GitHubSource, token::AbstractString, archive::AbstractString)::Nothing
    check_token(token, source.host)
    auth = "Authorization" => "Bearer $token"
    downloader = Downloads.Downloader()
    url = download_url(source, auth; downloader)
    download_archive(url, archive, [download_headers(url); auth], ["Authorization"]; downloader)
end

function gh_fetch(source::GitHubSource, archive::AbstractString, artifact::AbstractString)::Nothing
    gh = gh_renames(source.host) ? nothing : find_program("gh")
    gh === nothing && no_token_error(
        source.host, artifact,
        ", or install the GitHub CLI (https://cli.github.com/) and run `gh auth login --hostname $(source.host)`",
    )
    token = nothing
    # A server that only claims to be GitHub could pass the device login of gh on
    # to github.com and receive the github.com token.
    if github_host(source.host) == source.host && login_allowed()
        token = gh_stored_token(gh, source.host)
        token === nothing && login_once(
            () -> gh_stored_token(gh, source.host) !== nothing, () -> gh_login(gh, source.host, artifact),
        )
    end
    gh_download(gh, source, source.location, archive, artifact) && return
    token_download(source, token === nothing ? gh_token(gh, source.host) : token, archive)
end

function fetch_archive(source::GitHubSource, archive::AbstractString, artifact::AbstractString)::Nothing
    token = find_token(source.host, artifact)
    token === nothing ? gh_fetch(source, archive, artifact) : token_download(source, token, archive)
end
