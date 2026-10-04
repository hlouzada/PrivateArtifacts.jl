# `endpoint` is `nothing` for Amazon S3. `region` is `nothing` when the AWS CLI
# uses its configured region.
struct S3Source <: Source
    uri::String
    region::Union{String, Nothing}
    endpoint::Union{String, Nothing}
end

# `bucket` is `nothing` for a path-style host and `endpoint` is `nothing` for
# Amazon S3.
function s3_endpoint(authority::AbstractString)::Union{NamedTuple, Nothing}
    # `s3-external-1.amazonaws.com` is a legacy name of us-east-1. Website
    # endpoints serve no https, so `s3-website-*` is not a region.
    m = match(r"^(?:([a-z0-9][a-z0-9.-]{1,61}[a-z0-9])\.)?s3(?:(-external-1)\.amazonaws\.com|(?:-fips|-accelerate)?(?:\.dualstack)?(?:[.-]((?!website-)[a-z]+(?:-[a-z]+)+-[0-9]+))?\.amazonaws\.(?:com(?:\.cn)?|eu))\z", authority)
    m === nothing || return (; bucket = m[1], region = m[2] === nothing ? m[3] : "us-east-1", endpoint = nothing)
    m = match(r"^(?:([a-z0-9][a-z0-9.-]{1,61}[a-z0-9])\.)?([0-9a-f]{32}(?:\.[a-z]+)?\.r2\.cloudflarestorage\.com)\z", authority)
    m === nothing || return (; bucket = m[1], region = nothing, endpoint = "https://$(m[2])")
    nothing
end

# S3 reads `+` in a URL path as a space, so a literal `+` is rejected rather than guessed.
function percent_decode(path::AbstractString, url::AbstractString)::String
    occursin('+', path) && error("Write `+` as `%2B` and a space as `%20` in the S3 URL $url")
    occursin(r"^(?:[A-Za-z0-9._~!$&'()*,;=:@/-]|%[0-9A-Fa-f]{2})*\z", path) || error(
        "The S3 URL $url has a character that must be percent-encoded, or an invalid percent-encoding.",
    )
    decoded = unescape(path)
    isvalid(decoded) || error("The S3 URL $url does not decode to valid UTF-8.")
    decoded
end

function s3_uri_parts(url::AbstractString, host, region, artifact::AbstractString)::NamedTuple{(:bucket, :key, :endpoint, :region)}
    m = match(r"^s3://([^/]*)/(.*)\z"s, url)
    m === nothing && error("Expected an S3 URI `s3://<bucket>/<key>` for artifact `$artifact`, got $url")
    bucket, key = m.captures
    authority = host isa AbstractString && contains(host, r"^[A-Za-z0-9.-]+(?::[0-9]+)?\z") ? url_authority("https://$host") : nothing
    host === nothing || authority !== nothing || error(
        "The `host` of artifact `$artifact` must be a host name with an optional port, such as `minio.example.com:9000`, got `$(shown(host))`.",
    )
    (; bucket, key, endpoint = host === nothing ? nothing : "https://$authority", region)
end

function s3_https_parts(url::AbstractString, host, region, artifact::AbstractString)::NamedTuple{(:bucket, :key, :endpoint, :region)}
    host === nothing || error(
        "The `host` of artifact `$artifact` applies only to an `s3://` URL. An https URL names its host itself.",
    )
    authority = https_host(url)
    m = match(r"^https://[^/]+/([^?#]*)\z", url)
    m === nothing && error("Expected an S3 object URL without query or fragment for artifact `$artifact`, got $url")
    path = percent_decode(m[1], url)
    known = s3_endpoint(authority)
    if known !== nothing && known.bucket !== nothing
        bucket, key = known.bucket, path
    else
        bucket, key = something(match(r"^([^/]*)/?(.*)\z"s, path)).captures
    end
    endpoint = known === nothing ? "https://$authority" : known.endpoint
    if known !== nothing && known.region !== nothing
        region === nothing || region == known.region || error(
            "The `region` of artifact `$artifact` is `$region`, but its URL names the region `$(known.region)`.",
        )
        region = known.region
    end
    (; bucket, key, endpoint, region)
end

function s3_source(url::AbstractString, settings::AbstractDict, artifact::AbstractString)::S3Source
    check_settings(settings, ("host", "region"), "s3", artifact)
    region = get(settings, "region", nothing)
    region === nothing || region isa AbstractString && contains(region, r"^[a-z0-9-]+\z") || error(
        "The `region` of artifact `$artifact` must be an AWS region name, got `$(shown(region))`.",
    )
    host = get(settings, "host", nothing)
    parts = startswith(url, "s3://") ? s3_uri_parts : s3_https_parts
    (; bucket, key, endpoint, region) = parts(url, host, region, artifact)
    contains(bucket, r"^[A-Za-z0-9][A-Za-z0-9._-]{2,254}\z") || error("Invalid S3 bucket `$(shown(bucket))` in $url")
    isempty(key) && error("The S3 URL $url names no object.")
    S3Source("s3://$bucket/$key", region, endpoint)
end

function fetch_archive(source::S3Source, archive::AbstractString, artifact::AbstractString)::Nothing
    aws = find_program("aws")
    aws === nothing && error(
        "Artifact `$artifact` is at $(source.uri), which needs the AWS CLI (https://aws.amazon.com/cli/).",
    )
    region = source.region === nothing ? `` : `--region=$(source.region)`
    endpoint = source.endpoint === nothing ? `` : `--endpoint-url=$(source.endpoint)`
    command = aws_command(`$aws s3 cp $(source.uri) $archive --only-show-errors $region $endpoint`)
    message = "`aws s3 cp` failed for artifact `$artifact` from $(source.uri)."
    (; succeeded, errors) = run_cli(command, message)
    if !succeeded && login_allowed() && aws_exports_credentials(aws) && !aws_has_credentials(aws)
        login_once(() -> aws_has_credentials(aws), () -> aws_login(aws, artifact))
        (; succeeded, errors) = run_cli(command, message)
    end
    succeeded || error(rstrip("$message\n$errors"))
    nothing
end

function aws_command(command::Base.AbstractCmd)::Base.AbstractCmd
    # An interactive auto-prompt would wait for input that never comes.
    command = addenv(command, "AWS_CLI_AUTO_PROMPT" => "off")
    with_config_dir(command, AWS_CONFIG_DIR_ENV, ["AWS_CONFIG_FILE" => "config", "AWS_SHARED_CREDENTIALS_FILE" => "credentials"])
end

# `aws configure export-credentials` exists since 2.9.
function aws_exports_credentials(aws::AbstractString)::Bool
    (; succeeded, output) = run_cli(aws_command(`$aws --version`), "Checking the AWS CLI version failed.")
    m = match(r"^aws-cli/([0-9]+\.[0-9]+\.[0-9]+)", output)
    succeeded && m !== nothing && VersionNumber(m[1]) >= v"2.9"
end

aws_has_credentials(aws::AbstractString)::Bool = succeeds(aws_command(`$aws configure export-credentials`), "Checking the AWS CLI credentials failed.")

const AWS_CREDENTIAL_SOURCES = ("role_arn", "credential_process", "credential_source", "web_identity_token_file")
const AWS_CREDENTIAL_SOURCE_ENVS = (
    "AWS_ROLE_ARN", "AWS_WEB_IDENTITY_TOKEN_FILE", "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI", "AWS_CONTAINER_CREDENTIALS_FULL_URI",
)

function aws_login(aws::AbstractString, artifact::AbstractString)::Nothing
    configured(key) = succeeds(aws_command(`$aws configure get $key`), "Reading the AWS CLI profile failed.")
    if configured("sso_session") || configured("sso_start_url")
        arguments = ["sso", "login"]
    elseif configured("login_session")
        arguments = ["login"]
    else
        # `aws configure get` reads only the profile itself, not a source profile
        # or the environment.
        key = findfirst(configured, AWS_CREDENTIAL_SOURCES)
        variable = findfirst(name -> env(name) !== nothing, AWS_CREDENTIAL_SOURCE_ENVS)
        source =
            key !== nothing ? "its profile sets `$(AWS_CREDENTIAL_SOURCES[key])`" :
            variable !== nothing ? "`$(AWS_CREDENTIAL_SOURCE_ENVS[variable])` is set" :
            nothing
        source === nothing || error(
            "The AWS CLI has no credentials for artifact `$artifact`, and $source. " *
            "Log in for the source of these credentials, then load the artifact again.",
        )
        arguments = ["configure"]
    end
    run_login(aws_command(`$aws $arguments`), join(["aws"; arguments], " "), artifact, "needs AWS CLI credentials")
end
