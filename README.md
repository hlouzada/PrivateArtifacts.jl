# PrivateArtifacts.jl

`PrivateArtifacts` implements authenticated downloads from private sources to
Julia's artifact system. It behaves similarly to `LazyArtifacts.jl`.

Credentials come from environment variables or from the command-line tools that already manage
them for each service: [`gh`](https://cli.github.com/) for GitHub,
[`glab`](https://gitlab.com/gitlab-org/cli) for GitLab and the
[AWS CLI](https://aws.amazon.com/cli/) for S3 (see [Authentication](#authentication)).

## Macro Usage

`PrivateArtifacts` exports an `@artifact_str` macro, it locates `Artifacts.toml` relative
to the source file that contains the call and checks for `download_private` entries. Any
other ones are passed through to `Artifacts.@artifact_str`.

```julia
using PrivateArtifacts

artifact_path = artifact"libtbos"
library_path = artifact"libtbos/lib/libtbos.so"
```

The call forms of `Artifacts.@artifact_str` work the same way for private
artifacts. The name can be computed at run time, and a platform argument
selects among platform-specific entries:

```julia
using Base.BinaryPlatforms: Platform

name = "libtbos"
artifact_path = @artifact_str(name)
windows_path = @artifact_str("libtbos", Platform("x86_64", "windows"))
```

## Private Download entries

Private artifact downloads are defined similarly to regular artifacts in `Artifacts.toml`
(see [#Artifacts.toml-files](https://pkgdocs.julialang.org/v1/artifacts/#Artifacts.toml-files)),
they share the same `[[<name>]]` platform tables containing the `git-tree-sha1`, `os`, and `arch` fields,
but uses `[[<name>.download_private]]` tables instead of `[[<name>.download]]` tables. Each entry contains
the usual `url` and `sha256` fields, an optional `kind` field and extra options depending on the kind
(see [#Source Kinds](#source-kinds)).

```toml
[[libtbos]]
os = "linux"
arch = "x86_64"
git-tree-sha1 = "0123456789abcdef0123456789abcdef01234567"

    [[libtbos.download_private]]
    url = "s3://private-artifacts/libtbos-x86_64-linux-gnu.tar.gz"
    sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    [[libtbos.download_private]]
    url = "https://downloads.example.com/libtbos.tar.gz"
    sha256 = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
    kind = "http"

[[libtbos]]
os = "windows"
arch = "x86_64"
git-tree-sha1 = "fedcba9876543210fedcba9876543210fedcba98"

    [[libtbos.download_private]]
    url = "https://github.com/private-artifacts/libtbos/releases/download/v0.1.0/libtbos-x86_64-windows-msvc.tar.gz"
    sha256 = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
```

As with `Artifacts.jl`, the hash of the unpacked artifact needs to match `git-tree-sha1`
and so does `sha256` against the downloaded archive. Artifact locations in `Overrides.toml`
take precedence over `download_private` entries.

## Authentication

Credentials are looked up at download time, separately for each `download_private` entry.
Each source kind has its own way to obtain them (see [#Source Kinds](#source-kinds)).

| Kind                | Credentials                                   | Automatic login                |
|---------------------|-----------------------------------------------|--------------------------------|
| [`github`](#github) | Token variable, otherwise `gh`                | `github.com` and `*.ghe.com`   |
| [`gitlab`](#gitlab) | Token variable, otherwise `glab`              | `gitlab.com`                   |
| [`http`](#http)     | Token variable only                           | None                           |
| [`s3`](#s3)         | The AWS CLI and its usual credential chain    | Yes, with AWS CLI 2.9 or newer |

### Environment Variables

| Variable                             | Effect                                                         |
|--------------------------------------|----------------------------------------------------------------|
| `JULIA_PA_ARTIFACT_TOKEN_<ARTIFACT>` | Token for one artifact. Checked first.                         |
| `JULIA_PA_HOST_TOKEN_<HOST>`         | Token for every artifact on one host. Checked second.          |
| `JULIA_PA_LOGIN`                     | `true` or `false`. Whether a CLI may run an interactive login. |
| `JULIA_PA_GH_CONFIG_DIR`             | Sets `GH_CONFIG_DIR` for `gh`.                                 |
| `JULIA_PA_GLAB_CONFIG_DIR`           | Sets `GLAB_CONFIG_DIR` for `glab`.                             |
| `JULIA_PA_AWS_CONFIG_DIR`            | Sets `AWS_CONFIG_FILE` and `AWS_SHARED_CREDENTIALS_FILE` for `aws` to the `config` and `credentials` files in this directory. |

A variable with an empty value counts as unset.

#### Token Variables

The `github`, `gitlab` and `http` kinds accept a token from a token variable. The `s3` kind
ignores them. `<ARTIFACT>` is the artifact name in uppercase, with every character that is
not a letter or digit replaced by `_`. `<HOST>` is the host of the URL, followed by the port
when it is not 443. It is converted to uppercase after `-` is replaced by `__`, `.` by `_`,
and `:` by `___`.

| Artifact or host               | Variable                                     |
|--------------------------------|----------------------------------------------|
| artifact `my-lib.v2`           | `JULIA_PA_ARTIFACT_TOKEN_MY_LIB_V2`          |
| host `github.com`              | `JULIA_PA_HOST_TOKEN_GITHUB_COM`             |
| host `gitlab.example.com`      | `JULIA_PA_HOST_TOKEN_GITLAB_EXAMPLE_COM`     |
| host `my-files.example.com`    | `JULIA_PA_HOST_TOKEN_MY__FILES_EXAMPLE_COM`  |
| host `ghe.example.com:8443`    | `JULIA_PA_HOST_TOKEN_GHE_EXAMPLE_COM___8443` |

- A token variable takes precedence over `gh` and `glab`. When one is set, the CLI is not run.
- The artifact variable applies to every `download_private` entry of that artifact, whatever
  its host. Use host variables when the entries of one artifact live on different hosts.
- The package never reads `GH_TOKEN`, `GITHUB_TOKEN`, `GITLAB_TOKEN` or similar variables
  itself. They only affect the CLIs, as described for each kind.
- A token that contains a control character, such as a trailing newline, is rejected.

#### CLI Configuration Directories

`JULIA_PA_GH_CONFIG_DIR`, `JULIA_PA_GLAB_CONFIG_DIR` and `JULIA_PA_AWS_CONFIG_DIR` point the
CLIs to a separate configuration directory, so that credentials do not come from the user's
default configuration. Environment variables such as `GH_TOKEN` or `AWS_ACCESS_KEY_ID` still
apply.

```sh
export JULIA_PA_GH_CONFIG_DIR="$PWD/.credentials/gh"
export JULIA_PA_GLAB_CONFIG_DIR="$PWD/.credentials/glab"
export JULIA_PA_AWS_CONFIG_DIR="$PWD/.credentials/aws"
```

### Automatic Login

When a CLI has no credentials, the package can run its login command in the terminal. This
works for `github.com`, `*.ghe.com`, `gitlab.com` and the AWS CLI. Self-hosted GitHub and
GitLab servers are never logged in automatically, because a server that only claims to be
GitHub or GitLab could pass the login on to `github.com` or `gitlab.com` and receive that
token. Log in to those hosts once by hand before loading the artifact.

`JULIA_PA_LOGIN` controls whether a login may run. When it is unset, login is allowed only if
standard input, output and error are all terminals. Precompilation, `Pkg.build` and captured
output then fail instead of waiting on a prompt that nobody sees. Set it to `false` in CI.

### Where Tokens Are Sent

- A token is sent only to the host of the URL. For GitHub, it is also sent to the API host.
- When a redirect leaves the scheme, host and port of the first URL, the headers that carry
  the token are dropped. A release asset that redirects to a storage service therefore
  receives no token.
- Redirects from HTTPS to plain HTTP are refused.

### CI Example

A GitHub Actions job that loads artifacts from private repositories on `github.com`:

```yaml
env:
  JULIA_PA_LOGIN: "false"
  JULIA_PA_HOST_TOKEN_GITHUB_COM: ${{ secrets.ARTIFACTS_TOKEN }}
```

By default, the `GITHUB_TOKEN` of a workflow can only read the repository that runs it. Use a
token with read access to the artifact repositories.

## Source Kinds

The `kind` option in a download entry selects both how the URL is interpreted and how credentials
are obtained. If omitted, the package infers it from the provided URL:

- GitHub hosts and GitHub release/API URL patterns become `github`.
- `gitlab.com` and GitLab API, release, package, raw, or job URL patterns
	become `gitlab`.
- `s3://` URLs, Amazon S3 hostnames, and recognized Cloudflare R2 hostnames
	become `s3`.
- Other URLs become `http`.

The allowed values are `github`, `gitlab`, `http`, and `s3`.

### GitHub

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

**With a [token variable](#token-variables)**, `gh` is not used. The token is sent as
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

1. For `github.com` and `*.ghe.com`, when [automatic login](#automatic-login) is allowed, it
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

### GitLab

GitLab entries support the `headers` option, which works the same as for [HTTP](#http). The
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

**With a [token variable](#token-variables)**, `glab` is not used.

**Without a token variable**, the package reads the token with
`glab config get token --host HOST`:

- `glab` runs in an empty temporary directory, so the `glab` configuration of the current
  repository does not apply.
- `glab` returns the value of `GITLAB_TOKEN`, `GITLAB_ACCESS_TOKEN` or `OAUTH_TOKEN` for any
  host. The package passes these variables to `glab` only for its default host. That is the
  host from `glab config get host`, or `gitlab.com` when none is configured.
- If `glab` has no token for `gitlab.com` and [automatic login](#automatic-login) is allowed,
  the package runs `glab auth login --hostname gitlab.com`.

Self-managed GitLab hosts need a previous `glab auth login --hostname HOST`.

### HTTP

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

The token comes only from a [token variable](#token-variables). There is no CLI fallback. A
missing token raises an error that names both variables.

### S3

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

- [automatic login](#automatic-login) is allowed,
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

## Hash Behavior

`JULIA_PKG_IGNORE_HASHES` behaves as in `Pkg`. When true, a `git-tree-sha1` mismatch is logged
and the unpacked artifact is kept. The `sha256` check of the archive is always enforced.
