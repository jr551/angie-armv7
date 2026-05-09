# angie-armv7

Builds [Angie](https://angie.software/) (an nginx fork) from source for `linux/arm/v7`,
since upstream publishes only `amd64` and `arm64`.

Image: `ghcr.io/jr551/angie:armv7` (also tagged `ghcr.io/jr551/angie:<version>-armv7`).
Used on a MikroTik L009UiGS-2HaxD as a public-facing reverse proxy.

See [DEPLOY.md](DEPLOY.md) for how the image is wired up on the router (NAT, certs, etc.).

## Rebuilding

### Bumping the Angie version

1. Edit the `ANGIE_VERSION` `ARG` default at the top of `Dockerfile`.
2. Edit the default in `.github/workflows/build.yml` (in two places: the
   `workflow_dispatch.inputs.angie_version.default` and the `${{ inputs.angie_version || '...' }}`
   fallbacks).
3. Commit & push to `main`. The workflow rebuilds and pushes:
   - `ghcr.io/jr551/angie:armv7` (rolling)
   - `ghcr.io/jr551/angie:<version>-armv7` (immutable)

Latest tags are listed at <https://download.angie.software/files/> (`angie-X.Y.Z.tar.gz`).

### Manual rebuild without bumping

`gh workflow run build-armv7 -R jr551/angie-armv7` — or trigger from the Actions tab,
optionally passing a different `angie_version` input.

### Build locally (if you have working buildx)

```sh
docker buildx build --platform linux/arm/v7 \
  --build-arg ANGIE_VERSION=1.11.4 \
  -t ghcr.io/jr551/angie:armv7 \
  --push .
```

QEMU emulation is required on amd64/arm64 hosts; expect ~10 min for the compile.

## What's in the image

Built with these modules (see `Dockerfile` for the exact `./configure` line):

- HTTP/1.1, HTTP/2, HTTP/3 (`--with-http_v2_module`, `--with-http_v3_module`)
- TLS (`--with-http_ssl_module`)
- realip, stub_status, gzip_static, sub, auth_request
- stream + stream_ssl
- pcre2 with JIT, threads, file-aio (note: file-aio prints `io_setup() failed` warnings on
  RouterOS containers — harmless, workers fall back automatically)

User/group `angie` is created at runtime. Logs are symlinked to stdout/stderr by default;
mount a custom `angie.conf` to change that or to add server blocks.

## Image size & footprint

Roughly 15 MB compressed. Idle RAM on the L009 is ~5–15 MB.

## Package visibility

The ghcr package is public so the router can pull anonymously. If you fork this and want
your own private registry, set `registry-url` and `username` on `/container/config` on the
MikroTik before adding the container.
