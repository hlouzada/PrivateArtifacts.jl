# Source Kinds

The `kind` option in a download entry selects both how the URL is interpreted and how credentials
are obtained. If omitted, the package infers it from the provided URL:

- GitHub hosts and GitHub release/API URL patterns become `github`.
- `gitlab.com` and GitLab API, release, package, raw, or job URL patterns
  become `gitlab`.
- `s3://` URLs, Amazon S3 hostnames, and recognized Cloudflare R2 hostnames
  become `s3`.
- Other URLs become `http`.

The allowed values are `github`, `gitlab`, `http`, and `s3`.

## GitHub

GitHub entries take no extra options. Release asset URLs are resolved through the GitHub API,
raw file URLs are downloaded from the GitHub API, and other HTTPS URLs are downloaded directly.
GitHub Enterprise hosts are supported by setting `kind = "github"`.

```toml
[[model.download_private]]
url = "https://github.com/acme/model/raw/91f3ecf327d1de943fe076657833252791ba9f60/model.tar.gz"
sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

[[model.download_private]]
kind = "github"
url = "https://ghe.example.com/acme/model/releases/download/v3.1.0/model.tar.gz"
sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
```

The API is at `https://api.github.com` for `github.com`, at `https://api.NAME.ghe.com` for
`NAME.ghe.com`, and at `https://HOST/api/v3` for any other host.

URLs on `www.github.com`, `api.github.com` and `raw.githubusercontent.com` have the host
`github.com`. URLs on `api.NAME.ghe.com` have the host `NAME.ghe.com`. So
`JULIA_PA_HOST_TOKEN_GITHUB_COM` covers all GitHub URLs.

**With a [token variable](@ref "Token Variables")**, `gh` is not used. The token is sent as
`Authorization: Bearer <token>`:

- A release download URL `https://HOST/OWNER/REPO/releases/download/TAG/FILE` is looked up
  with the REST API, and the asset is downloaded from the API.
- A raw file URL `https://HOST/OWNER/REPO/raw/REF/PATH` is downloaded from the contents
  endpoint of the REST API, `API/repos/OWNER/REPO/contents/PATH?ref=REF`. The web host does
  not accept API tokens for files of private repositories.
- Any other URL is downloaded directly.

In a raw file URL, `REF` is a commit, a branch or tag name, `refs/heads/NAME` or
`refs/tags/NAME`. The name must not contain `/`, because the rest of the URL is read as the
path. Use the commit for a branch or tag such as `release/v1`.

**Without a token variable**, the package uses `gh`:

1. For `github.com` and `*.ghe.com`, when [automatic login](@ref "Automatic Login") is allowed, it
   checks `gh auth token --hostname HOST` and runs `gh auth login --hostname HOST` if `gh` has
   no token.
2. A release download URL is downloaded with `gh release download`.
3. A raw file URL is downloaded with `gh api` from the same contents endpoint.
4. Other URLs, and release files whose names contain `*`, `?`, `[`, `]` or `\`, are downloaded
   with the token from `gh auth token --hostname HOST`.

GitHub Enterprise Server hosts need a previous `gh auth login --hostname HOST`. Hosts that end
in `.github.com` or `.localhost`, and subdomains of `NAME.ghe.com`, never use `gh` because
`gh` treats them as a different host. They need a token variable.

`gh` itself reads `GH_TOKEN` and `GITHUB_TOKEN` for `github.com`, and `GH_ENTERPRISE_TOKEN`
and `GITHUB_ENTERPRISE_TOKEN` for other hosts. The package passes `GH_TOKEN` and
`GITHUB_TOKEN` to `gh` only for `github.com`. It passes the enterprise variables only for the
host named in `GH_HOST`. This keeps a token away from hosts it was not issued for.

## GitLab

GitLab entries support the `headers` option, which works the same as for [HTTP](@ref "HTTP"). The
default header is `Authorization = "Bearer {token}"`. To send the token in another header,
such as GitLab's `PRIVATE-TOKEN`, set `headers`.

```toml
[[package.download_private]]
kind = "gitlab"
url = "https://gitlab.example.com/acme/package/-/releases/v2/downloads/package.tar.gz"
sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
headers = { Authorization = "Bearer {token}", Accept = "application/octet-stream" }
```

A token is needed only when a header contains `{token}`.

**With a [token variable](@ref "Token Variables")**, `glab` is not used.

**Without a token variable**, the package reads the token with
`glab config get token --host HOST`:

- `glab` runs in an empty temporary directory, so the `glab` configuration of the current
  repository does not apply.
- `glab` returns the value of `GITLAB_TOKEN`, `GITLAB_ACCESS_TOKEN` or `OAUTH_TOKEN` for any
  host. The package passes these variables to `glab` only for its default host. That is the
  host from `glab config get host`, or `gitlab.com` when none is configured.
- If `glab` has no token for `gitlab.com` and [automatic login](@ref "Automatic Login") is allowed,
  the package runs `glab auth login --hostname gitlab.com`.

Self-managed GitLab hosts need a previous `glab auth login --hostname HOST`.

## HTTP

HTTP entries require an HTTPS URL with a valid DNS hostname and support only the `headers`
option. The default is `Authorization = "Bearer {token}"`, where `{token}` is replaced with the
token.

```toml
[[data.download_private]]
kind = "http"
url = "https://downloads.example.com/data.tar.gz"
sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
headers = { Authorization = "Token {token}", Accept = "application/gzip" }
```

`headers` replaces the default as a whole. Keep a header with `{token}` in it, or the download
is anonymous. Header names and values must be strings. Connection-control headers such as
`Host`, `Content-Length`, and `Transfer-Encoding` are rejected.

The token comes only from a [token variable](@ref "Token Variables"). There is no CLI fallback. A
missing token raises an error that names both variables.

## S3

S3 entries are downloaded with `aws s3 cp` and support the `region` and `host` options. `host`
selects an S3-compatible server and is only allowed with `s3://` URLs, since an HTTPS URL names
its own host.

```toml
[[data.download_private]]
kind = "s3"
url = "s3://private-artifacts/releases/data.tar.gz"
sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
region = "eu-west-1"

[[data.download_private]]
kind = "s3"
url = "s3://artifacts/releases/data.tar.gz"
host = "minio.example.com:9000"
sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

[[data.download_private]]
kind = "s3"
url = "https://artifacts.s3.eu-west-1.amazonaws.com/releases/data.tar.gz"
sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
```

Credentials come from the usual AWS CLI credential chain: environment variables such as
`AWS_ACCESS_KEY_ID` and `AWS_PROFILE`, the shared `config` and `credentials` files, IAM
Identity Center (SSO), and instance or container roles. Token variables are not used.

For an S3-compatible server, given by `host` or by an HTTPS URL outside Amazon S3, the package
passes `--endpoint-url` to the AWS CLI. The credentials still come from the same chain. Select
a profile that holds keys for that server, for example with `AWS_PROFILE`.

When `aws s3 cp` fails, the package logs in and retries once if all of these hold:

- [automatic login](@ref "Automatic Login") is allowed,
- the AWS CLI is version 2.9 or newer,
- `aws configure export-credentials` finds no credentials.

The login command depends on the active profile:

| Active profile                                                                          | Login command              |
|-----------------------------------------------------------------------------------------|----------------------------|
| sets `sso_session` or `sso_start_url`                                                   | `aws sso login`            |
| sets `login_session`                                                                    | `aws login`                |
| sets `role_arn`, `credential_process`, `credential_source` or `web_identity_token_file` | None. The download fails.  |
| none of the above                                                                       | `aws configure`            |

The download also fails without a login when `AWS_ROLE_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE`,
`AWS_CONTAINER_CREDENTIALS_RELATIVE_URI` or `AWS_CONTAINER_CREDENTIALS_FULL_URI` is set. In
these cases the credentials come from another source, and you need to log in there.
