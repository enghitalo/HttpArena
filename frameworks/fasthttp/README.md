# fasthttp

A raw multi-threaded [V](https://vlang.io) HTTP server built on the `fasthttp`
module from V's standard library (epoll, non-blocking, `SO_REUSEPORT`).

## Implemented tests

| Test | Endpoint |
|------|----------|
| `baseline` | `GET/POST /baseline11` (handles chunked) |
| `pipelined` | `GET /pipeline` |
| `json` | `GET /json/{count}?m=M` over `/data/dataset.json` |
| `async-db` | `GET /async-db?min&max&limit` via `db.pg` |

## Stack

* [V](https://vlang.io) — pinned master commit `c0624b274` (built from source)
* [fasthttp](https://modules.vlang.io/fasthttp.html) — epoll HTTP server, built
  with `-prealloc` (per-request memory arena, freed after each request, no GC)
* `db.pg` (stdlib) — pooled Go-style PostgreSQL driver (`db.exec_param_many`)

JSON responses are built in a single allocation (precomputed prefixes +
`strings.Builder`) with no per-request reflection.
