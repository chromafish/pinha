# pinha

Git hosting: a Phoenix application that serves bare repositories from one
directory on disk. It creates and deletes repositories, browses branches,
commits, files, and diffs, resolves Jujutsu change ids, and speaks git's smart
HTTP protocol for clone, fetch, and push.

Git is the source of truth for repository contents: there is no index, and
every page reads the bare repository through `git`. Postgres holds one thing,
which git cannot: who may reach the server.

## Running it

```sh
mix deps.get
export DATABASE_URL=postgresql://user:password@host/pinha
mix ecto.migrate
PINHA_REPO_ROOT=/srv/pinha mix phx.server
```

Then open <http://localhost:4000>. The first person to reach `/signup` claims
the server, and sign-up closes behind them.

## Configuration

| Variable | Meaning | Default |
| --- | --- | --- |
| `PINHA_REPO_ROOT` | Directory holding every `<name>.git` | `tmp/repos` in dev |
| `PINHA_LISTEN_ADDRESS` | IP address to bind | all interfaces |
| `PORT` | TCP port to listen on | `4000` |
| `PINHA_BASE_URL` | Public URL used for clone commands, and the WebAuthn relying party | `http://localhost:4000` |
| `SECRET_KEY_BASE` | Cookie signing secret (production only) | required in prod |
| `DATABASE_URL` | Postgres holding the accounts | required in prod |
| `PINHA_SIGNUP_OPEN` | Keep sign-up open after the first user | `false` |
| `POOL_SIZE` | Database connections | `5` |

Deployment is a single release plus the repo directory:

```sh
MIX_ENV=prod mix release
PHX_SERVER=true PINHA_REPO_ROOT=/srv/pinha PINHA_BASE_URL=https://git.example.com \
  DATABASE_URL=postgresql://user:password@host/pinha \
  SECRET_KEY_BASE=$(mix phx.gen.secret) _build/prod/rel/pinha/bin/pinha start
```

Serve it over HTTPS. Browsers refuse the passkey API outside a secure context,
so sign-in only works over TLS, or on `localhost` while developing.

Backup and restore are filesystem copies: `rsync` or a volume snapshot of the
repo root, plus whatever backs up the database. There is no quota, so a full
disk fails the push.

## Repositories

The repo root holds one flat level of bare repositories: `$ROOT/foo.git`,
never `$ROOT/group/foo.git`. `HEAD` sets the default branch and `description`
feeds the repo list. Creating a repository by hand with `mkdir` plus
`git init --bare` is equivalent to using the API.

Create initializes into a temporary directory and renames it into place, so a
half-created repository is never listed; concurrent creates of one name
serialize and the loser gets 409. Delete renames the directory out of the
listing first, so new requests stop resolving it while in-flight ones drain,
then removes it in the background. Rename is delete plus create; update is
push.

## Accounts

Sign-in is a passkey: `/signup` registers one, `/signin` asks the browser for
any it holds for this server, and there is no password to type or store.

A git client cannot answer a WebAuthn challenge, so clone and push use a token
minted at `/settings` instead. Your email is the username, the token is the
password:

```sh
git clone https://you@example.com:pinha_xxx@git.example.com/demo.git
```

A credential helper stores it after the first prompt.

Everything but `/signin`, `/signup`, and `/metrics` requires a user. Lose every
passkey and the way back is the release console, which authorizes one
registration for fifteen minutes:

```sh
_build/prod/rel/pinha/bin/pinha rpc 'Pinha.Accounts.Recovery.authorize("you@example.com")'
```

## Routes

| Route | Purpose |
| --- | --- |
| `GET /` | Repo list: name, default-branch head, description |
| `POST /repos` | Create a repository from a `name` |
| `DELETE /:repo` | Delete a repository |
| `GET /:repo` | Summary: default branch, branches, tags, recent commits |
| `GET /:repo/tree/:rev/*path` | File listing or blob at `:rev` |
| `GET /:repo/raw/:rev/*path` | Raw blob bytes |
| `GET /:repo/commit/:id` | Metadata, parents, and the full diff |
| `GET /:repo/info/refs` | Ref advertisement |
| `POST /:repo/git-upload-pack` | Clone and fetch |
| `POST /:repo/git-receive-pack` | Push |
| `GET /metrics` | Prometheus text |
| `GET /signup`, `GET /signin` | Passkey registration and sign-in |
| `DELETE /signout` | End the session |
| `GET /settings` | Passkeys and API tokens |

`GET /` and `POST /repos` answer JSON for clients that do not ask for HTML, and
take an API token over HTTP Basic in place of a session.

A `:rev` resolves as full commit id first, then branch, then tag, then
Jujutsu change id (full or unique prefix). Short commit ids are not resolved,
while change-id prefixes are; an ambiguous prefix lists every match, and
divergent commits sharing one change id are shown individually.

`:rev` is one path segment, so a branch whose name contains a slash is
reachable by clone and push but not by the browse URLs. Blobs larger than 5 MB
are linked rather than rendered; the raw route always serves the exact bytes.

## Jujutsu

`jj git clone`, `jj git fetch`, and `jj git push` use the same smart HTTP
endpoints as git. The server never runs `jj` and never rewrites commits: it
reads the `change-id` trailer clients write and preserves it verbatim.

## Operating

Logs go to stdout as JSON, one canonical widelog line per HTTP request:
timestamp, method, route, repo, rev, git protocol (`upload-pack`,
`receive-pack`, or `none`), status, duration, request and response bytes, and
user agent. Push lines also carry per-ref old and new tips, truncated after
`:log_max_refs` refs.

`GET /metrics` exposes, with no auth:

- `http_requests_total{route,status}`
- `http_request_duration_ms` (histogram)
- `git_fetches_total{repo}`
- `git_pushes_total{repo}`
- `git_ref_updates_total{repo}`
- `repos_total`
- `repo_disk_bytes{repo}` (cached `du`, refreshed every 60s)

Maintenance runs in supervised background processes: a task after each
receive runs `git gc --auto`, and a periodic job prunes and repacks every
repository without blocking push responses.

## Tests

```sh
export TEST_DATABASE_URL=postgresql://user:password@host/pinha_test
mix test
```

The suite drives a real `git` client against the running endpoint: clone,
fetch, push, force-push, tag and branch deletion, protocol v2, and gzipped
request bodies, all of it authenticated with a token.

The passkey ceremonies themselves are not covered: verifying an attestation
needs an authenticator, so the tests exercise everything around it and write
credential rows directly.
