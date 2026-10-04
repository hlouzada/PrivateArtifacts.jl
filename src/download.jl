const REDIRECT_STATUSES = (301, 302, 303, 307, 308)
const MAX_REDIRECTS = 10

function redirect_target(url::AbstractString, response)::String
    index = findfirst(((name, _),) -> lowercase(name) == "location", response.headers)
    # Downloads drops a header that is not valid UTF-8.
    index === nothing && error("The redirect from $(redact(url)) has no valid `Location` header.")
    target = resolve_reference(url, encode_location(String(strip(last(response.headers[index])))))
    scheme = match(r"^(https?)://"i, target)
    scheme !== nothing && !(startswith(lowercase(url), "https:") && lowercase(scheme[1]) == "http") || error(
        "Refusing the redirect from $(redact(url)) to $(redact(target)).",
    )
    target
end

# Keeps the existing hook. A new downloader has the global `Downloads.EASY_HOOK`.
function with_curl_options(f::Function, downloader::Downloads.Downloader, options::Pair...)
    hook = downloader.easy_hook
    downloader.easy_hook = (easy, info) -> begin
        hook === nothing || hook(easy, info)
        for (option, value) in options
            Downloads.Curl.setopt(easy, option, value)
        end
    end
    try
        f()
    finally
        downloader.easy_hook = hook
    end
end

# Redirects are followed here because libcurl forwards every header except
# `Authorization` to another host. The headers named in `secrets` are dropped once
# a redirect leaves the origin of `url`.
function download_archive(
    url::AbstractString, archive::AbstractString, headers::AbstractVector, secrets::AbstractVector;
    downloader::Downloads.Downloader = Downloads.Downloader(),
)::Nothing
    with_curl_options(downloader, Downloads.Curl.CURLOPT_FOLLOWLOCATION => false) do
        start, current = origin(url), url
        for redirects in 0:MAX_REDIRECTS
            failure = try
                Downloads.download(current, archive; headers, downloader)
                return nothing
            catch err
                err isa Downloads.RequestError || rethrow()
                err
            end
            # Errors are thrown outside the `catch` so that the request error is not
            # shown as their cause. The URL of a redirect target can hold a signature.
            # The status line comes from the server and may hold control characters.
            if !(failure.response.status in REDIRECT_STATUSES)
                message = sprint(showerror, failure)
                redirects == 0 && error(escape_controls(message))
                error("Downloading $(shown(url)) failed after a redirect: $(escape_controls(replace(message, current => redact(current))))")
            end
            current = redirect_target(current, failure.response)
            origin(current) == start || (headers = filter(((name, _),) -> !(name in secrets), headers))
        end
        error("Too many redirects from $(shown(url)).")
    end
end
