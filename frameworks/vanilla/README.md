# vanilla

[vanilla](https://github.com/enghitalo/vanilla) is a minimalist, high-performance
HTTP server written in [V](https://vlang.io) — multi-threaded, non-blocking
epoll I/O, lock-free, copy-free, with `SO_REUSEPORT`.

## Implemented tests

| Test | Endpoint | Notes |
|------|----------|-------|
| `baseline` | `GET/POST /baseline11` | `a + b` (+ request body on POST); handles chunked + fragmented requests |
| `pipelined` | `GET /pipeline` | returns `ok` |
| `json` | `GET /json/{count}?m=M` | processes `/data/dataset.json`, adds `total = price*quantity*M` |
| `async-db` | `GET /async-db?min&max&limit` | `SELECT … FROM items WHERE price BETWEEN min AND max LIMIT limit` via `db.pg` |

> `POST /upload` is implemented too, but `vanilla` caps a single request at 8 MiB
> (a built-in DoS guard), so the `upload` profile (20 MiB bodies) is not subscribed.

## Stack

* [V](https://vlang.io) 0.5.1 (pinned prebuilt release)
* [vanilla](https://github.com/enghitalo/vanilla) — raw epoll HTTP server
* `db.pg` (stdlib) — pooled PostgreSQL driver, sized from `DATABASE_MAX_CONN`
* `json` (stdlib) — dataset parsing + response serialization

## Environment

* `DATABASE_URL` — Postgres connection URI (async-db)
* `DATABASE_MAX_CONN` — connection pool size
* `DATASET_PATH` — dataset location (defaults to `/data/dataset.json`)
