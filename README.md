# pinha

Git hosting: a Phoenix application that serves bare repositories from one
directory on disk. It creates and deletes repositories, browses branches,
commits, files, and diffs, resolves Jujutsu change ids, and serves clone,
fetch, and push over both git's smart HTTP protocol and SSH.

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

Then open <http://localhost:4000>. A server with no users writes a claim URL
to its log when it starts; opening that URL and registering a passkey creates
the admin account. Everyone after that needs an invite.

## Configuration

| Variable | Meaning | Default |
| --- | --- | --- |
| `PINHA_REPO_ROOT` | Directory holding every `<name>.git` | `tmp/repos` in dev |
| `PINHA_LISTEN_ADDRESS` | IP address to bind | all interfaces |
| `PORT` | TCP port to listen on | `4000` |
| `PINHA_BASE_URL` | Public URL used for clone commands, and the WebAuthn relying party | `http://localhost:4000` |
| `PINHA_SSH_PORT` | Port the SSH listener binds | `2222` |
| `PINHA_SSH_HOST` | Host written into SSH clone URLs | host of `PINHA_BASE_URL` |
| `PINHA_SSH_HOST_KEY_DIR` | Directory holding the host key | `.pinha/ssh` under the repo root |
| `PINHA_SSH_ENABLED` | Set to `false` to run without SSH | `true` |
| `SECRET_KEY_BASE` | Cookie signing secret (production only) | required in prod |
| `DATABASE_URL` | Postgres holding the accounts | required in prod |
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

The SSH listener is Erlang's own, inside the release: there is no OpenSSH, no
OS account per user, and no `authorized_keys` file. It generates an Ed25519
host key on first boot and prints the fingerprint:

```
20:02:11.884 [info] ssh listening on port 2222, host key SHA256:xlqJQiS+RpQ…
```

That key lives under the repo root by default, so a backup of the root carries
it and clients keep their `known_hosts` entry across a restore. Binding port 22
needs a privileged process or a redirect; the default is 2222 so the release
can run unprivileged.

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

A registration is admitted by a token and nothing else. On a server nobody has
claimed, that is the claim token printed at boot, and the account it creates is
the admin:

```
19:58:33.286 [info] no users yet: claim this server at https://git.example.com/signup?claim=t3PN…
```

It lasts fifteen minutes and dies with the node; `pinha rpc
'Pinha.Accounts.Registration.claim()'` mints another. After that, an admin
mints invites at `/settings` and hands them over by whatever channel they
already have with the person, since the server sends no mail. An invite is
shown once, admits one account, and expires in a week.

A git client cannot answer a WebAuthn challenge, so clone and push use a token
minted at `/settings` instead. Your email is the username, the token is the
password:

```sh
git clone https://you@example.com:pinha_xxx@git.example.com/demo.git
```

A credential helper stores it after the first prompt.

SSH is the other way in, and the nicer one to push with: register a public key
at `/settings`, pasted in `authorized_keys` form, and the agent answers for
you.

```sh
git clone ssh://git@git.example.com:2222/demo.git
```

Everyone connects as `git`, which is not an OS account: the key says who you
are. Ed25519, ECDSA, and RSA of at least 2048 bits are accepted, a fingerprint
belongs to one account, and deleting the row revokes it. A session may run
`git-upload-pack` or `git-receive-pack` against one repository and nothing
else: no shell, no terminal, no sftp, no forwarding.

Everything but `/signin`, `/signup`, and `/metrics` requires a user. Lose every
passkey and the way back is the release console, which authorizes one
registration for fifteen minutes. The email names the account; nothing is sent
to it:

```sh
_build/prod/rel/pinha/bin/pinha rpc 'Pinha.Accounts.Registration.authorize("you@example.com")'
```

## Access

Every user reads every repository. Writing is narrower: pushing to a
repository, deleting it, or handing it to someone else is the owner and
admins, over either transport.

A repository records its owner in its own git config, as a `pinha.owner`
entry holding the opaque `uid` the server minted for that account. It lives in
git so a repository restored from a filesystem copy carries its owner, and the
`uid` outlives anything a user can change about themselves. Whoever creates a
repository owns it; the repo page hands it to someone else by email, and so
does the release console:

```sh
_build/prod/rel/pinha/bin/pinha rpc 'Pinha.Repos.set_owner("demo", "you@example.com")'
```

A repository with no owner, made by hand with `git init --bare` or left behind
by a deleted account, stays readable by everyone and writable by admins until
one assigns an owner.

## Routes

| Route | Purpose |
| --- | --- |
| `GET /` | Repo list: name, default-branch head, description |
| `POST /repos` | Create a repository from a `name` |
| `DELETE /:repo` | Delete a repository (owner or admin) |
| `POST /:repo/owner` | Hand a repository to the user with this `email` |
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
| `GET /settings` | Passkeys, API tokens, SSH keys, and invites for an admin |

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

`jj git clone`, `jj git fetch`, and `jj git push` use the same endpoints and
the same SSH listener as git. The server never runs `jj` and never rewrites
commits: it reads the `change-id` trailer clients write and preserves it
verbatim.

## Operating

Logs go to stdout as JSON, one canonical widelog line per request:
timestamp, transport (`http` or `ssh`), method, route, repo, rev, git protocol
(`upload-pack`, `receive-pack`, or `none`), status, duration, request and
response bytes, and user agent. An SSH session writes one line of the same
shape per exec, carrying the peer address and git's exit status. Push lines
also carry per-ref old and new tips, truncated after `:log_max_refs` refs.

`GET /metrics` exposes, with no auth:

- `http_requests_total{route,status}`
- `http_request_duration_ms` (histogram)
- `git_fetches_total{repo,transport}`
- `git_pushes_total{repo,transport}`
- `git_ref_updates_total{repo}`
- `ssh_auth_failures_total`
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
request bodies, all of it authenticated with a token. The SSH tests do the
same through a real `ssh`, against the listener the application started, with
a key pair `ssh-keygen` made for the test.

The passkey ceremonies themselves are not covered: verifying an attestation
needs an authenticator, so the tests exercise everything around it and write
credential rows directly.
