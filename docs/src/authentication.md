# Authentication

Credentials are looked up at download time, separately for each `download_private` entry.
Each source kind has its own way to obtain them (see [#Source Kinds](@ref "Source Kinds")).

| Kind                      | Credentials                                | Automatic login                |
|---------------------------|--------------------------------------------|--------------------------------|
| [`github`](@ref "GitHub") | Token variable, otherwise `gh`             | `github.com` and `*.ghe.com`   |
| [`gitlab`](@ref "GitLab") | Token variable, otherwise `glab`           | `gitlab.com`                   |
| [`http`](@ref "HTTP")     | Token variable only                        | None                           |
| [`s3`](@ref "S3")         | The AWS CLI and its usual credential chain | Yes, with AWS CLI 2.9 or newer |

## Environment Variables

| Variable                             | Effect                                                         |
|--------------------------------------|----------------------------------------------------------------|
| `JULIA_PA_ARTIFACT_TOKEN_<ARTIFACT>` | Token for one artifact. Checked first.                         |
| `JULIA_PA_HOST_TOKEN_<HOST>`         | Token for every artifact on one host. Checked second.          |
| `JULIA_PA_LOGIN`                     | `true` or `false`. Whether a CLI may run an interactive login. |
| `JULIA_PA_GH_CONFIG_DIR`             | Sets `GH_CONFIG_DIR` for `gh`.                                 |
| `JULIA_PA_GLAB_CONFIG_DIR`           | Sets `GLAB_CONFIG_DIR` for `glab`.                             |
| `JULIA_PA_AWS_CONFIG_DIR`            | Sets `AWS_CONFIG_FILE` and `AWS_SHARED_CREDENTIALS_FILE` for `aws` to the `config` and `credentials` files in this directory. |

A variable with an empty value counts as unset.

### Token Variables

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

### CLI Configuration Directories

`JULIA_PA_GH_CONFIG_DIR`, `JULIA_PA_GLAB_CONFIG_DIR` and `JULIA_PA_AWS_CONFIG_DIR` point the
CLIs to a separate configuration directory, so that credentials do not come from the user's
default configuration. Environment variables such as `GH_TOKEN` or `AWS_ACCESS_KEY_ID` still
apply.

```sh
export JULIA_PA_GH_CONFIG_DIR="$PWD/.credentials/gh"
export JULIA_PA_GLAB_CONFIG_DIR="$PWD/.credentials/glab"
export JULIA_PA_AWS_CONFIG_DIR="$PWD/.credentials/aws"
```

## Automatic Login

When a CLI has no credentials, the package can run its login command in the terminal. This
works for `github.com`, `*.ghe.com`, `gitlab.com` and the AWS CLI. Self-hosted GitHub and
GitLab servers are never logged in automatically, because a server that only claims to be
GitHub or GitLab could pass the login on to `github.com` or `gitlab.com` and receive that
token. Log in to those hosts once by hand before loading the artifact.

`JULIA_PA_LOGIN` controls whether a login may run. When it is unset, login is allowed only if
standard input, output and error are all terminals. Precompilation, `Pkg.build` and captured
output then fail instead of waiting on a prompt that nobody sees. Set it to `false` in CI.

## Where Tokens Are Sent

- A token is sent only to the host of the URL. For GitHub, it is also sent to the API host.
- When a redirect leaves the scheme, host and port of the first URL, the headers that carry
  the token are dropped. A release asset that redirects to a storage service therefore
  receives no token.
- Redirects from HTTPS to plain HTTP are refused.

## CI Example

A GitHub Actions job that loads artifacts from private repositories on `github.com`:

```yaml
env:
  JULIA_PA_LOGIN: "false"
  JULIA_PA_HOST_TOKEN_GITHUB_COM: ${{ secrets.ARTIFACTS_TOKEN }}
```

By default, the `GITHUB_TOKEN` of a workflow can only read the repository that runs it. Use a
token with read access to the artifact repositories.
