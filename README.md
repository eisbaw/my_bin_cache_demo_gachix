# my_bin_cache_demo_gachix

A demonstration that **a GitHub repository can be the storage backend of a Nix
binary cache** — including a CI pipeline that uses it as a **read-write
pull-through cache** so a derivation is built at most once.

Built with [Gachix](https://github.com/EphraimSiegfried/gachix), which stores Nix
packages directly as Git objects (file → blob, directory → tree, package →
commit, dependency → parent commit) under custom refs:

- `refs/<nix-hash>/result`  → the package **commit** (its tree is the package contents)
- `refs/<nix-hash>/narinfo` → a **blob** holding the narinfo metadata

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
GitHub repo (git objects)  --mirror clone-->  gachix serve  --HTTP-->  nix
```

## CI: read-write pull-through cache

[`.github/workflows/use-gachix-cache.yml`](./.github/workflows/use-gachix-cache.yml)
runs on every push and on manual dispatch. Each run:

1. **Mirror-clones** this repo (the custom `refs/<hash>/*` come along — a plain
   clone won't fetch them).
2. Runs the published **`ephraimsiegfried/gachix`** Docker image as the proxy,
   serving the cache over HTTP on `127.0.0.1:8080`.
3. Installs **Determinate Nix**, configured with the proxy as a substituter and
   the cache's public key trusted.
4. `nix build .#hello-html` — **substituted on a cache hit, built locally on a miss**.
5. On a miss, **signs and `gachix add`s** the built path (talking to the runner's
   Nix daemon over a mounted socket), then **`git push`es** the new
   `refs/<hash>/*` back here.

Net effect: the first run builds and populates the cache; every later run
substitutes it and never rebuilds. Observed in two consecutive runs:

```
Run 1:  CACHE MISS  ->  built locally        ->  signed + pushed back
Run 2:  CACHE HIT   ->  substituted from cache (no rebuild)
```

The cache is signed; CI trusts the key `gachix-ci-1`. The signing secret is held
as the GitHub Actions secret `GACHIX_SIGNING_KEY` (never committed).

## Serving / consuming it yourself

```sh
# 1. Mirror-clone so the custom refs/<hash>/* come along.
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

- **The cache only grows** — nothing prunes old `refs/<hash>/*`.
- **No locking** — concurrent runs building the *same* new derivation will both
  build and race on the push (idempotent content, last write wins).
- **Trust** — anyone able to run the workflow can sign paths into the cache, so
  it triggers only on push to `main` and manual dispatch (no `pull_request`).
