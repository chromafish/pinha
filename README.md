# pinha

A software forge.

## Why?

It came up to me in a dream.

## Running it

Setup a `.env` with `DATABASE_URL=<some-postgres-url>`

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
| `PINHA_SSH_ADDRESS` | IP address the SSH listener binds | all interfaces |
| `PINHA_SSH_HOST_KEY_DIR` | Directory holding the host key | `.pinha/ssh` under the repo root |
| `PINHA_SSH_ENABLED` | Set to `false` to run without SSH | `true` |
| `HONEYCOMB_API_KEY` | Ingest key for the trace exporter; unset means traces go nowhere | none |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Where traces are exported | `https://api.honeycomb.io` |
| `OTEL_SERVICE_NAME` | Service name on the spans | `pinha` |
| `SECRET_KEY_BASE` | Cookie signing secret (production only) | required in prod |
| `DATABASE_URL` | Postgres holding the accounts | required in prod |
| `POOL_SIZE` | Database connections | `5` |

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

## Releasing

Tag the revision, then package it:

```sh
jj tag set v0.1.0
scripts/release.sh v0.1.0
```

The script checks the tag out and builds it. Three files are built in `dist/`
(`--out DIR` to put them elsewhere): the tarball, its SHA-256, and a manifest
naming the tag, the revision, the toolchain, the platform, and the checksum.

A release carries the BEAM it was built against, so it runs on the OS and
architecture it was built on and no other.

## Deploying

See `server/README.md

## Repositories

Currently the implementation is quite naive, and all repo operations are done
by shelling out `git` and `jj` processes.

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

git clients can use a token minted at `/settings` instead. Your email is the username,
the token is the password:

```sh
git clone https://you@example.com:pinha_xxx@git.example.com/r/demo.git
```

A credential helper stores it after the first prompt.

SSH is the other way in:

```sh
git clone ssh://git@git.example.com:2222/demo.git   # /r/demo.git too
```

Everything but `/signin` and `/signup` requires a user. Lose every
passkey and the way back is the release console, which authorizes one
registration for fifteen minutes. The email names the account; nothing is sent
to it:

```sh
_build/prod/rel/pinha/bin/pinha rpc 'Pinha.Accounts.Registration.authorize("you@example.com")'
```

## Operating

Logs go to stdout as JSON, one canonical widelog line per request, `event`
naming which kind it is: timestamp, transport (`http` or `ssh`), method, route,
repo, rev, git protocol (`upload-pack`, `receive-pack`, or `none`), status,
duration, request and response bytes, and user agent. An SSH session writes one
line of the same shape per exec, carrying the peer address and git's exit status.
Push lines also carry per-ref old and new tips, truncated after `:log_max_refs` refs.

Traces are OpenTelemetry over OTLP. The HTTP surface comes from the events
Phoenix, Bandit and Ecto already emit; neither git transport is Phoenix, so
each carries spans of its own — one per advertisement, `upload-pack` or
`receive-pack`, one per git subprocess, one per SSH session — naming the repo,
the subcommand, the user, the bytes moved, and git's stderr when it failed.

Without `HONEYCOMB_API_KEY` the spans are created and go nowhere, which is
what a development machine wants; the suite never exports whatever is in the
environment. There are no counters of the server's own, so how many pushes,
how slow, and by whom is a query over the spans.

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
