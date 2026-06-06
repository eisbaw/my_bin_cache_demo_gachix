# my_bin_cache_demo_gachix

A demonstration that **a GitHub repository can be the storage backend of a Nix
binary cache**, using [Gachix](https://github.com/EphraimSiegfried/gachix).

Gachix stores Nix packages directly as Git objects (file → blob, directory →
tree, package → commit, dependency → parent commit) under custom refs:

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
binary-cache protocol, which GitHub does not serve. You need a running
`gachix serve` process to bridge Git → HTTP:

```
GitHub repo (git objects)  --git fetch-->  gachix serve  --HTTP-->  nix
```

## Serving this cache

```sh
# 1. Mirror-clone so the custom refs/<hash>/* come along (a plain clone won't).
git clone --mirror https://github.com/eisbaw/my_bin_cache_demo_gachix.git cache

# 2. Point gachix at it and serve (no Nix needed on this machine).
#    config.yaml: store.path: ./cache, use_local_nix_daemon: false
gachix -c config.yaml serve            # listens on http://localhost:8080

# 3. Tell nix to use it as a substituter. The cache is signed, so trust its key.
nix build .#hello-html \
  --substituters http://127.0.0.1:8080 \
  --option extra-trusted-public-keys \
    "my-bin-cache-demo-gachix-1:kcxihECOFVeKOVHp+yUU5uoaq4OaIgr6gDCqHHX6hw4="
```

> Use `127.0.0.1`, not `localhost` (Docker's published port is IPv4-only).
> A GitHub Actions workflow (`.github/workflows/use-gachix-cache.yml`) runs this
> whole flow on every push, with Determinate Nix configured to use the cache.

## Status

Proof-of-concept. Gachix itself is marked "not ready for production", and its
git-remote replication path is largely untested — this repo exercises the
storage-and-serve path only.
