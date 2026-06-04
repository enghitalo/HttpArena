# vanilla

[vanilla](https://github.com/enghitalo/vanilla) is a minimalist, high-performance
HTTP server written in [V](https://vlang.io) — multi-threaded, non-blocking
epoll I/O, lock-free, copy-free, with `SO_REUSEPORT`.

## Implemented profiles

| Profile | Endpoint | Notes |
|---|---|---|
| `baseline` | `GET/POST /baseline11` | `a + b` (+ body on POST); handles chunked + TCP-fragmented requests |
| `pipelined` | `GET /pipeline` | returns `ok` |
| `limited-conn` | `GET /baseline11` | short-lived connections |
| `json` | `GET /json/{count}?m=M` | single-allocation response, precomputed item prefixes |
| `json-comp` | `GET /json/...` + `Accept-Encoding` | gzip-compressed response |
| `static` | `GET /static/<file>` | assets preloaded into memory, MIME by extension, 404 on miss |
| `async-db` | `GET /async-db?min&max&limit` | `db.pg` ConnectionPool |
| `fortunes` | `GET /fortunes` | DB rows + runtime row, HTML-escaped |
| `api-4`, `api-16` | mixed baseline + json + async-db | |

## Stack

* [V](https://vlang.io) 0.5.1 (pinned prebuilt release)
* [vanilla](https://github.com/enghitalo/vanilla) — raw epoll HTTP server
* `db.pg`, `json`, `compress.gzip` (stdlib)

## Environment

* `DATABASE_URL`, `DATABASE_MAX_CONN` — Postgres connection + pool size
* `DATASET_PATH` (default `/data/dataset.json`), `STATIC_DIR` (default `/data/static`)

> The `upload` profile (20 MiB bodies) lands once
> [enghitalo/vanilla#17](https://github.com/enghitalo/vanilla/pull/17)
> (configurable `max_request_bytes`) is merged; until then vanilla caps a single
> request at 8 MiB. HTTP/2, HTTP/3 and gRPC profiles need protocol support
> vanilla doesn't have yet (tracked upstream).
