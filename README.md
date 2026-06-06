# my_bin_cache_demo_gachix

A demonstration that **a GitHub repository can be the storage backend of a Nix
binary cache** — including a CI pipeline that uses it as a **read-write
pull-through cache** so a derivation is built at most once.

Built with a **fork of [Gachix](https://github.com/EphraimSiegfried/gachix)**
([`eisbaw/gachix`](https://github.com/eisbaw/gachix), vendored as the
[`gachix/`](./gachix) submodule on branch `sharded-refs`) that reworks the ref
layout and concurrency model for scale — see [Scalability fixes](#scalability-fixes).

Gachix stores Nix packages directly as Git objects (file → blob, directory →
tree). In this fork each package is **one commit on a sharded branch**:

```
refs/heads/gachix/<shard>/<hash>   ->  commit
    tree    = the package contents          (streamed on demand as the NAR)
    parents = the dependency commits        (the closure IS the commit DAG)
    message = the signed narinfo metadata
<shard> = first 2 chars of the 32-char base32 store hash  (1024 buckets)
```

So this very repository *is* the cache. The packaged artifact is a trivial
`cmark` markdown→HTML derivation defined in [`flake.nix`](./flake.nix).

## What is stored here

```
nix build .#hello-html
# -> /nix/store/<hash>-hello-html   (a single hello.html, no runtime deps)
```

## Important: GitHub is the storage, not the substituter

`nix` cannot fetch from this repo directly — it speaks the HTTP narinfo/nar
binary-cache protocol, which GitHub does not serve. A running `gachix serve`
process bridges Git → HTTP:

```
GitHub repo (git objects)  --git fetch-->  gachix serve  --HTTP-->  nix
```

## CI: read-write pull-through cache

[`.github/workflows/use-gachix-cache.yml`](./.github/workflows/use-gachix-cache.yml)
runs on every push to `main` and on manual dispatch. Each run:

1. Restores a **persisted bare cache repo** (`actions/cache`) and fetches **only**
   the package branches `refs/heads/gachix/*` as full objects — namespace-scoped,
   never a mirror clone, and never `--filter` (libgit2 cannot lazy-fetch missing
   objects, so a blobless clone would break serving).
2. Runs the forked **`ghcr.io/eisbaw/gachix`** image as the proxy on `127.0.0.1:8080`.
3. Installs **Determinate Nix**, configured with the proxy as a substituter and
   the cache's public key trusted.
4. `nix build .#hello-html` — **substituted on a cache hit, built locally on a miss**.
5. On a miss, **signs and `gachix add`s** the built path (via the runner's Nix
   daemon over a mounted socket), then **pushes** the new `refs/heads/gachix/*`.

Net effect: the first run builds and populates the cache; every later run
substitutes it and never rebuilds:

```
Run 1:  CACHE MISS  ->  built locally        ->  signed + pushed back
Run 2:  CACHE HIT   ->  substituted from cache (no rebuild)
```

The image is published by [`gachix/.github/workflows/publish-ghcr.yml`](./gachix/.github/workflows/publish-ghcr.yml).
The cache is signed; CI trusts the key `gachix-ci-1`. The signing secret is the
GitHub Actions secret `GACHIX_SIGNING_KEY` (never committed); the push uses a
one-off tokenized URL argument so the persisted cache cannot leak the token.

## Scalability fixes

This fork addresses the worst ceilings of the git-as-cache approach:

- **Sharded `gachix/` branches, one commit per package.** Collapsing the old
  `result` commit + `narinfo` blob into a single commit (narinfo in the message)
  halves the ref count and makes publish **atomic**. `refs/heads` are
  GitHub-native (a normal clone fetches them) and sharded into 1024 buckets.
  *Honest limit:* sharding does not remove git's O(total-refs) ref advertisement
  on every connect — only a single-index-object design would; it does fix
  loose-ref/filesystem cost and enables shard-scoped partial replication.
- **Per-operation libgit2 handles.** The previous `Arc<RwLock<Repository>>` +
  `unsafe impl Sync` was unsound (concurrent NAR streams raced on one shared
  libgit2 handle). Each operation/stream now owns its own `Repository`; no global
  lock, no `unsafe`.
- **Namespace-scoped CI fetch** instead of mirror-cloning the whole repo per run.

## Serving / consuming it yourself

```sh
# 1. A normal clone fetches the gachix/ branches (refs/heads); mirror also works.
git clone --mirror https://github.com/eisbaw/my_bin_cache_demo_gachix.git cache

# 2. Point gachix at it and serve (no Nix needed on this machine).
#    config.yaml: store.path: ./cache, use_local_nix_daemon: false
gachix -c config.yaml serve            # listens on 127.0.0.1:8080

# 3. Tell nix to use it as a substituter. The cache is signed, so trust its key.
nix build .#hello-html \
  --substituters http://127.0.0.1:8080 \
  --option extra-trusted-public-keys \
    "gachix-ci-1:yZUPdH0jbeU23e/qXD+VARO8tGUumOXiuhPfwGq3Uzg="
```

> Use `127.0.0.1`, not `localhost` — Docker's published port is IPv4-only and
> `localhost` may resolve to `::1`.

## Status & limitations

Proof-of-concept; Gachix itself is marked "not ready for production". Known
limits of this demo:

- **The cache only grows** — nothing prunes old branches.
- **Ref advertisement is still O(total refs)** — sharding mitigates filesystem
  cost but not the per-connect advertisement; not for org/public scale.
- **No locking** — concurrent runs building the *same* new derivation both build
  and race on the push (idempotent content, last write wins).
- **Single signing key on every runner** — anyone able to run the workflow can
  sign paths into the cache, so it triggers only on push to `main` and manual
  dispatch (no `pull_request`).
- **GitHub is a demo host, not infra** — repo-size / push / abuse limits make
  this unsuitable as a production substituter backend.
