# pinha

Git hosting: a Phoenix application that serves bare repositories from one
directory on disk. It creates and deletes repositories, browses branches,
commits, files, and diffs, resolves Jujutsu change ids, and speaks git's smart
HTTP protocol for clone, fetch, and push.

Git is the source of truth. There is no database and no index: every page
reads the bare repository through `git`.

## Running it

```sh
mix deps.get
PINHA_REPO_ROOT=/srv/pinha mix phx.server
```

Then open <http://localhost:4000>.

## Configuration

| Variable | Meaning | Default |
| --- | --- | --- |
| `PINHA_REPO_ROOT` | Directory holding every `<name>.git` | `tmp/repos` in dev |
| `PINHA_LISTEN_ADDRESS` | IP address to bind | all interfaces |
| `PORT` | TCP port to listen on | `4000` |
| `PINHA_BASE_URL` | Public URL used for clone commands | `http://localhost:4000` |
| `SECRET_KEY_BASE` | Cookie signing secret (production only) | required in prod |

Deployment is a single release plus the repo directory:

```sh
MIX_ENV=prod mix release
PHX_SERVER=true PINHA_REPO_ROOT=/srv/pinha PINHA_BASE_URL=https://git.example.com \
  SECRET_KEY_BASE=$(mix phx.gen.secret) _build/prod/rel/pinha/bin/pinha start
```

Backup and restore are filesystem copies: `rsync` or a volume snapshot of the
repo root. There is no quota, so a full disk fails the push.

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

`GET /` and `POST /repos` answer JSON for clients that do not ask for HTML.

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
mix test
```

The suite drives a real `git` client against the running endpoint: clone,
fetch, push, force-push, tag and branch deletion, protocol v2, and gzipped
request bodies.
