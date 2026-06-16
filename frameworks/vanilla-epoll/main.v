module main

import vanilla.http_server
import vanilla.http_server.http1_1.request_parser
import vanilla.http_server.core
import vanilla.pg_async
import json
import os
import runtime
import strings
import sync
import compress.gzip

struct Rating {
	score i64
	count i64
}

// Dataset item as stored in /data/dataset.json.
struct DatasetItem {
	id       i64
	name     string
	category string
	price    i64
	quantity i64
	active   bool
	tags     []string
	rating   Rating
}

// A static asset served with sendfile(2): the response head is precomputed, the
// body is streamed zero-copy straight from the page-cached file fd.
struct StaticFile {
	header []u8
	fd     int
	size   i64
}

fn C.open(pathname &char, flags int) int

struct CrudCreate {
	id       int
	name     string
	category string
	price    int
	quantity int
}

struct Fortune {
	id      int
	message string
}

// Shared is the process-wide state, shared by reference across all workers: the
// read-only dataset/prefixes/assets, plus the crud cache-aside and json-comp
// caches. The caches are SHARED (not per-worker) so the crud X-Cache MISS→HIT
// contract holds regardless of which worker SO_REUSEPORT routes a request to;
// they are guarded by RwMutexes since workers are separate threads.
struct Shared {
	dataset  []DatasetItem
	prefixes []string
	assets   map[string]StaticFile
mut:
	cache    map[int][]u8 // crud cache-aside: id -> full item response bytes
	cache_mu &sync.RwMutex = unsafe { nil }
	gz_cache map[u64][]u8 // json-comp: (count<<32)|m -> gzipped response bytes
	gz_mu    &sync.RwMutex = unsafe { nil }
}

// WorkerCtx is the per-worker state handed to every handler call as ac.state
// (the make_state contract). Each worker owns its own async Postgres pool;
// `ro` points at the process-shared Shared.
struct WorkerCtx {
mut:
	ro   &Shared          = unsafe { nil }
	pool &pg_async.PgPool = unsafe { nil }
}

// Stash is the per-request state that must survive across the park (the request
// buffer is recycled while a query is in flight). One small heap struct per DB
// request; the single resume continuation switches on `kind`.
struct Stash {
	kind     u8
	conn_idx int
	id       int
	page     i64
}

const k_async_db = u8(1)
const k_fortunes = u8(2)
const k_crud_get = u8(3)
const k_crud_list = u8(4)
const k_crud_create = u8(5)
const k_crud_update = u8(6)

// ── zero-alloc write helpers (push_many, never single-element `<<`) ──────────

@[inline]
fn ws(mut out []u8, s string) {
	unsafe { out.push_many(s.str, s.len) }
}

@[inline]
fn wb(mut out []u8, b []u8) {
	unsafe { out.push_many(b.data, b.len) }
}

@[direct_array_access]
fn wi(mut out []u8, n i64) {
	mut tmp := [20]u8{}
	if n == 0 {
		tmp[0] = u8(`0`)
		unsafe { out.push_many(&tmp[0], 1) }
		return
	}
	mut x := n
	mut neg := false
	if x < 0 {
		neg = true
		x = -x
	}
	mut i := 20
	for x > 0 {
		i--
		tmp[i] = u8(`0`) + u8(x % 10)
		x /= 10
	}
	if neg {
		i--
		tmp[i] = u8(`-`)
	}
	unsafe { out.push_many(&tmp[i], 20 - i) }
}

// ws_json_str appends a JSON-escaped string value (no surrounding quotes). Fast
// path: most values have no special characters, so emit them as one bulk copy.
@[direct_array_access]
fn ws_json_str(mut out []u8, s []u8) {
	mut needs := false
	for c in s {
		if c == `"` || c == `\\` || c < 0x20 {
			needs = true
			break
		}
	}
	if !needs {
		wb(mut out, s)
		return
	}
	for c in s {
		match c {
			`"` { ws(mut out, '\\"') }
			`\\` { ws(mut out, '\\\\') }
			`\n` { ws(mut out, '\\n') }
			`\r` { ws(mut out, '\\r') }
			`\t` { ws(mut out, '\\t') }
			else { unsafe { out.push_many(&c, 1) } }
		}
	}
}

// emit writes a complete 200 response with a precomputed body into `out`.
fn emit(mut out []u8, ctype string, body []u8) {
	ws(mut out, 'HTTP/1.1 200 OK\r\nServer: vanilla\r\nContent-Type: ')
	ws(mut out, ctype)
	ws(mut out, '\r\nContent-Length: ')
	wi(mut out, i64(body.len))
	ws(mut out, '\r\nConnection: keep-alive\r\n\r\n')
	wb(mut out, body)
}

fn write_resp(mut out []u8, ctype string, body string) {
	ws(mut out, 'HTTP/1.1 200 OK\r\nServer: vanilla\r\nContent-Type: ')
	ws(mut out, ctype)
	ws(mut out, '\r\nContent-Length: ')
	wi(mut out, i64(body.len))
	ws(mut out, '\r\nConnection: keep-alive\r\n\r\n')
	ws(mut out, body)
}

const not_found = 'HTTP/1.1 404 Not Found\r\nServer: vanilla\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

const created = 'HTTP/1.1 201 Created\r\nServer: vanilla\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

const bad_request = 'HTTP/1.1 400 Bad Request\r\nServer: vanilla\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

// ── async handler ────────────────────────────────────────────────────────────

fn handle(req_buffer []u8, mut out []u8, mut ac core.AsyncCtx) core.AsyncStep {
	mut w := unsafe { &WorkerCtx(ac.state) }
	req := request_parser.decode_http_request(req_buffer) or {
		wb(mut out, bad_request)
		return .done
	}
	method := unsafe { tos(&req.buffer[req.method.start], req.method.len) }
	target := unsafe { tos(&req.buffer[req.path.start], req.path.len) }
	qpos := target.index_u8(`?`)
	route := if qpos < 0 { target } else { unsafe { tos(target.str, qpos) } }

	if route == '/pipeline' {
		write_resp(mut out, 'text/plain', 'ok')
		return .done
	} else if route == '/baseline11' {
		mut sum := qint(req, qk_a) + qint(req, qk_b)
		if method == 'POST' {
			sum += body_int(req)
		}
		write_resp(mut out, 'text/plain', sum.str())
		return .done
	} else if route == '/upload' {
		cl := req.content_length()
		n := if cl >= 0 { i64(cl) } else { i64(req.body.len) }
		write_resp(mut out, 'text/plain', n.str())
		return .done
	} else if route.starts_with('/json/') {
		count := clamp_count(parse_u_at(route, 6), w.ro.dataset.len)
		mut m := qint(req, qk_m)
		if m == 0 {
			m = 1
		}
		if accepts_gzip(req) {
			w.write_json_gzip(mut out, count, m)
		} else {
			w.write_json_response(mut out, count, m)
		}
		return .done
	} else if route == '/async-db' {
		return w.start_async_db(mut out, mut ac, qint(req, qk_min), qint(req, qk_max), qint(req,
			qk_limit))
	} else if route == '/fortunes' {
		return w.start_fortunes(mut out, mut ac)
	} else if route.starts_with('/static/') {
		if f := w.ro.assets[route[8..]] {
			wb(mut out, f.header)
			core.queue_file(f.fd, 0, f.size)
		} else {
			wb(mut out, not_found)
		}
		return .done
	} else if route == '/crud/items' {
		if method == 'POST' {
			return w.start_crud_create(mut out, mut ac, req)
		}
		return w.start_crud_list(mut out, mut ac, qstr(req, qk_category), qint(req, qk_page), qint(req,
			qk_limit))
	} else if route.starts_with('/crud/items/') {
		id := int(parse_u_at(route, 12))
		if method == 'PUT' {
			return w.start_crud_update(mut out, mut ac, id, req)
		}
		return w.start_crud_get(mut out, mut ac, id)
	}
	wb(mut out, not_found)
	return .done
}

// park submits a query and parks the request on its connection, stashing the
// render kind (+ id/page for the routes that need them) for the continuation.
// On a pool/flush failure it answers synchronously with `fallback`.
fn (mut w WorkerCtx) park(mut out []u8, mut ac core.AsyncCtx, query_text string, params []?[]u8, kind u8, id int, page i64, fallback []u8) core.AsyncStep {
	idx := w.pool.acquire() or {
		wb(mut out, fallback)
		return .done
	}
	mut c := w.pool.conn(idx)
	c.async_submit(query_text, params)
	c.async_flush() or {
		w.pool.release(idx)
		wb(mut out, fallback)
		return .done
	}
	st := &Stash{
		kind:     kind
		conn_idx: idx
		id:       id
		page:     page
	}
	ac.watch(w.pool.fd(idx), .readable, on_db_ready, voidptr(st))
	return .suspend
}

// on_db_ready resumes a parked request when its PG socket is readable: pump the
// result, render by kind, release the connection.
fn on_db_ready(mut out []u8, mut ac core.AsyncCtx) core.AsyncStep {
	mut w := unsafe { &WorkerCtx(ac.state) }
	st := unsafe { &Stash(ac.udata) }
	mut c := w.pool.conn(st.conn_idx)
	poll := c.async_on_readable() or {
		w.pool.release(st.conn_idx)
		w.render_error(mut out, st.kind)
		return .done
	}
	if !poll.ready {
		ac.watch(w.pool.fd(st.conn_idx), .readable, on_db_ready, ac.udata) // more bytes to come
		return .suspend
	}
	res := poll.result
	match st.kind {
		k_async_db { w.render_async_db(mut out, res) }
		k_fortunes { render_fortunes(mut out, res) }
		k_crud_get { w.render_crud_get(mut out, res, st.id) }
		k_crud_list { render_crud_list(mut out, res, st.page) }
		k_crud_create { wb(mut out, created) }
		k_crud_update { w.render_crud_update(mut out, st.id) }
		else { wb(mut out, not_found) }
	}

	w.pool.release(st.conn_idx)
	return .done
}

fn (w &WorkerCtx) render_error(mut out []u8, kind u8) {
	match kind {
		k_async_db { write_resp(mut out, 'application/json', '{"items":[],"count":0}') }
		k_fortunes { write_resp(mut out, 'text/html; charset=utf-8',
				'<!doctype html><html><body><table></table></body></html>') }
		k_crud_list { write_resp(mut out, 'application/json', '{"items":[],"total":0,"page":1}') }
		k_crud_get { wb(mut out, not_found) }
		else { wb(mut out, bad_request) }
	}
}

// ── /async-db ────────────────────────────────────────────────────────────────

const async_db_sql = 'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN \$1 AND \$2 LIMIT \$3'

fn (mut w WorkerCtx) start_async_db(mut out []u8, mut ac core.AsyncCtx, min i64, max i64, limit i64) core.AsyncStep {
	mut lim := limit
	if lim < 1 {
		lim = 1
	}
	if lim > 50 {
		lim = 50
	}
	params := [?[]u8(min.str().bytes()), ?[]u8(max.str().bytes()), ?[]u8(lim.str().bytes())]
	return w.park(mut out, mut ac, async_db_sql, params, k_async_db, 0, 0,
		'{"items":[],"count":0}'.bytes())
}

fn (w &WorkerCtx) render_async_db(mut out []u8, res pg_async.Result) {
	mut body := []u8{cap: 4096}
	ws(mut body, '{"items":[')
	mut rows := res.rows()
	mut count := 0
	for {
		row := rows.next() or { break }
		if count > 0 {
			ws(mut body, ',')
		}
		render_item(mut body, row)
		count++
	}
	ws(mut body, '],"count":')
	wi(mut body, i64(count))
	ws(mut body, '}')
	emit(mut out, 'application/json', body)
}

// render_item writes one items-row as JSON. tags is JSONB read in binary: a
// 0x01 version byte then JSON text, so it is emitted RAW (already valid JSON) —
// no decode/re-encode round-trip.
@[direct_array_access]
fn render_item(mut body []u8, row pg_async.Row) {
	ws(mut body, '{"id":')
	wi(mut body, i64(row.int4(0) or { 0 }))
	ws(mut body, ',"name":"')
	ws_json_str(mut body, row.text(1) or { ''.bytes() })
	ws(mut body, '","category":"')
	ws_json_str(mut body, row.text(2) or { ''.bytes() })
	ws(mut body, '","price":')
	wi(mut body, i64(row.int4(3) or { 0 }))
	ws(mut body, ',"quantity":')
	wi(mut body, i64(row.int4(4) or { 0 }))
	ws(mut body, ',"active":')
	ws(mut body, if row.boolean(5) or { false } { 'true' } else { 'false' })
	ws(mut body, ',"tags":')
	wb(mut body, pg_async.jsonb_text(row.text(6) or { '[]'.bytes() }))
	ws(mut body, ',"rating":{"score":')
	wi(mut body, i64(row.int4(7) or { 0 }))
	ws(mut body, ',"count":')
	wi(mut body, i64(row.int4(8) or { 0 }))
	ws(mut body, '}}')
}

// ── /fortunes ────────────────────────────────────────────────────────────────

fn (mut w WorkerCtx) start_fortunes(mut out []u8, mut ac core.AsyncCtx) core.AsyncStep {
	return w.park(mut out, mut ac, 'SELECT id, message FROM fortune', []?[]u8{}, k_fortunes, 0, 0,
		'<!doctype html><html><body><table></table></body></html>'.bytes())
}

fn render_fortunes(mut out []u8, res pg_async.Result) {
	mut fortunes := []Fortune{}
	mut rows := res.rows()
	for {
		row := rows.next() or { break }
		fortunes << Fortune{
			id:      row.int4(0) or { 0 }
			message: (row.text(1) or { ''.bytes() }).bytestr().clone()
		}
	}
	fortunes << Fortune{
		id:      0
		message: 'Additional fortune added at request time.'
	}
	fortunes.sort(a.message < b.message)
	mut body := []u8{cap: 32768}
	ws(mut body,
		'<!doctype html><html><head><title>Fortunes</title></head><body><table><tr><th>id</th><th>message</th></tr>')
	for f in fortunes {
		ws(mut body, '<tr><td>')
		wi(mut body, i64(f.id))
		ws(mut body, '</td><td>')
		ws(mut body, escape_html(f.message))
		ws(mut body, '</td></tr>')
	}
	ws(mut body, '</table></body></html>')
	emit(mut out, 'text/html; charset=utf-8', body)
}

// ── /crud ────────────────────────────────────────────────────────────────────

// crud_list uses a single window-count query (count(*) OVER()) so the page and
// the total come back together — one park instead of two queries.
const crud_list_sql = 'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count, count(*) OVER() FROM items WHERE category = \$1 ORDER BY id LIMIT \$2 OFFSET \$3'

fn (mut w WorkerCtx) start_crud_list(mut out []u8, mut ac core.AsyncCtx, category string, page i64, limit i64) core.AsyncStep {
	mut p := page
	if p < 1 {
		p = 1
	}
	mut lim := limit
	if lim < 1 {
		lim = 10
	}
	if lim > 100 {
		lim = 100
	}
	offset := (p - 1) * lim
	params := [?[]u8(category.bytes()), ?[]u8(lim.str().bytes()), ?[]u8(offset.str().bytes())]
	return w.park(mut out, mut ac, crud_list_sql, params, k_crud_list, 0, p,
		'{"items":[],"total":0,"page":1}'.bytes())
}

fn render_crud_list(mut out []u8, res pg_async.Result, page i64) {
	mut body := []u8{cap: 8192}
	ws(mut body, '{"items":[')
	mut rows := res.rows()
	mut count := 0
	mut total := i64(0)
	for {
		row := rows.next() or { break }
		if count > 0 {
			ws(mut body, ',')
		}
		render_item(mut body, row)
		total = row.int8(9) or { 0 } // count(*) OVER() — same in every row
		count++
	}
	ws(mut body, '],"total":')
	wi(mut body, total)
	ws(mut body, ',"page":')
	wi(mut body, page)
	ws(mut body, '}')
	emit(mut out, 'application/json', body)
}

fn (mut w WorkerCtx) start_crud_get(mut out []u8, mut ac core.AsyncCtx, id int) core.AsyncStep {
	w.ro.cache_mu.@rlock()
	cached := w.ro.cache[id] or { []u8{} }
	w.ro.cache_mu.runlock()
	if cached.len > 0 {
		// Cache hit: answer synchronously, no DB round-trip.
		ws(mut out,
			'HTTP/1.1 200 OK\r\nServer: vanilla\r\nX-Cache: HIT\r\nContent-Type: application/json\r\nContent-Length: ')
		wi(mut out, i64(cached.len))
		ws(mut out, '\r\nConnection: keep-alive\r\n\r\n')
		wb(mut out, cached)
		return .done
	}
	params := [?[]u8(id.str().bytes())]
	return w.park(mut out, mut ac,
		'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE id = \$1',
		params, k_crud_get, id, 0, not_found)
}

fn (mut w WorkerCtx) render_crud_get(mut out []u8, res pg_async.Result, id int) {
	mut rows := res.rows()
	row := rows.next() or {
		wb(mut out, not_found)
		return
	}
	mut item := []u8{cap: 512}
	render_item(mut item, row)
	w.ro.cache_mu.@lock()
	w.ro.cache[id] = item // populate the shared cache-aside
	w.ro.cache_mu.unlock()
	ws(mut out,
		'HTTP/1.1 200 OK\r\nServer: vanilla\r\nX-Cache: MISS\r\nContent-Type: application/json\r\nContent-Length: ')
	wi(mut out, i64(item.len))
	ws(mut out, '\r\nConnection: keep-alive\r\n\r\n')
	wb(mut out, item)
}

fn (mut w WorkerCtx) start_crud_create(mut out []u8, mut ac core.AsyncCtx, req request_parser.HttpRequest) core.AsyncStep {
	raw := unsafe { tos(&req.buffer[req.body.start], req.body.len) }
	c := json.decode(CrudCreate, raw) or {
		wb(mut out, bad_request)
		return .done
	}
	params := [?[]u8(c.id.str().bytes()), ?[]u8(c.name.bytes()), ?[]u8(c.category.bytes()),
		?[]u8(c.price.str().bytes()), ?[]u8(c.quantity.str().bytes())]
	return w.park(mut out, mut ac,
		"INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count) VALUES (\$1, \$2, \$3, \$4, \$5, true, '[]', 0, 0) ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category, price = EXCLUDED.price, quantity = EXCLUDED.quantity",
		params, k_crud_create, 0, 0, bad_request)
}

fn (mut w WorkerCtx) start_crud_update(mut out []u8, mut ac core.AsyncCtx, id int, req request_parser.HttpRequest) core.AsyncStep {
	raw := unsafe { tos(&req.buffer[req.body.start], req.body.len) }
	c := json.decode(CrudCreate, raw) or {
		wb(mut out, bad_request)
		return .done
	}
	params := [?[]u8(id.str().bytes()), ?[]u8(c.name.bytes()), ?[]u8(c.category.bytes()),
		?[]u8(c.price.str().bytes()), ?[]u8(c.quantity.str().bytes())]
	return w.park(mut out, mut ac,
		'UPDATE items SET name = \$2, category = \$3, price = \$4, quantity = \$5 WHERE id = \$1',
		params, k_crud_update, id, 0, bad_request)
}

fn (mut w WorkerCtx) render_crud_update(mut out []u8, id int) {
	w.ro.cache_mu.@lock()
	w.ro.cache.delete(id) // invalidate the cache-aside entry
	w.ro.cache_mu.unlock()
	write_resp(mut out, 'application/json', '{"status":"ok"}')
}

// ── /json (non-DB) ───────────────────────────────────────────────────────────

fn (w &WorkerCtx) write_json_response(mut out []u8, count int, m i64) {
	// 21 = len('{"items":[') + len('],"count":') + '}'; plus the count's own digits
	mut clen := 21 + digits(i64(count))
	if count > 0 {
		clen += count - 1
	}
	for i in 0 .. count {
		t := w.ro.dataset[i].price * w.ro.dataset[i].quantity * m
		clen += w.ro.prefixes[i].len + digits(t) + 1
	}
	ws(mut out,
		'HTTP/1.1 200 OK\r\nServer: vanilla\r\nContent-Type: application/json\r\nContent-Length: ')
	wi(mut out, i64(clen))
	ws(mut out, '\r\nConnection: keep-alive\r\n\r\n{"items":[')
	for i in 0 .. count {
		ws(mut out, w.ro.prefixes[i])
		wi(mut out, w.ro.dataset[i].price * w.ro.dataset[i].quantity * m)
		ws(mut out, if i < count - 1 { '},' } else { '}' })
	}
	ws(mut out, '],"count":')
	wi(mut out, i64(count))
	ws(mut out, '}')
}

fn (mut w WorkerCtx) write_json_gzip(mut out []u8, count int, m i64) {
	key := (u64(u32(count)) << 32) | u64(u32(m))
	w.ro.gz_mu.@rlock()
	cached := w.ro.gz_cache[key] or { []u8{} }
	w.ro.gz_mu.runlock()
	if cached.len > 0 {
		wb(mut out, cached)
		return
	}
	body := w.json_body(count, m)
	gz := gzip.compress(body.bytes()) or {
		write_resp(mut out, 'application/json', body)
		return
	}
	mut resp := []u8{cap: gz.len + 128}
	ws(mut resp,
		'HTTP/1.1 200 OK\r\nServer: vanilla\r\nContent-Encoding: gzip\r\nContent-Type: application/json\r\nContent-Length: ')
	wi(mut resp, i64(gz.len))
	ws(mut resp, '\r\nConnection: keep-alive\r\n\r\n')
	unsafe { resp.push_many(gz.data, gz.len) }
	w.ro.gz_mu.@lock()
	if w.ro.gz_cache.len < 1024 {
		w.ro.gz_cache[key] = resp
	}
	w.ro.gz_mu.unlock()
	wb(mut out, resp)
}

fn (w &WorkerCtx) json_body(count int, m i64) string {
	mut sb := strings.new_builder(count * 224 + 32)
	sb.write_string('{"items":[')
	for i in 0 .. count {
		if i > 0 {
			sb.write_u8(`,`)
		}
		sb.write_string(w.ro.prefixes[i])
		sb.write_decimal(w.ro.dataset[i].price * w.ro.dataset[i].quantity * m)
		sb.write_u8(`}`)
	}
	sb.write_string('],"count":')
	sb.write_decimal(i64(count))
	sb.write_u8(`}`)
	return sb.str()
}

// ── helpers ──────────────────────────────────────────────────────────────────

fn escape_html(s string) string {
	mut needs := false
	for c in s {
		if c == `&` || c == `<` || c == `>` || c == `"` || c == `'` {
			needs = true
			break
		}
	}
	if !needs {
		return s
	}
	mut b := strings.new_builder(s.len + 16)
	for c in s {
		match c {
			`&` { b.write_string('&amp;') }
			`<` { b.write_string('&lt;') }
			`>` { b.write_string('&gt;') }
			`"` { b.write_string('&quot;') }
			`'` { b.write_string('&apos;') }
			else { b.write_u8(c) }
		}
	}
	return b.str()
}

fn digits(n i64) int {
	if n < 10 {
		return 1
	}
	mut x := n
	mut d := 0
	for x > 0 {
		d++
		x /= 10
	}
	return d
}

const qk_a = 'a'.bytes()
const qk_b = 'b'.bytes()
const qk_m = 'm'.bytes()
const qk_min = 'min'.bytes()
const qk_max = 'max'.bytes()
const qk_limit = 'limit'.bytes()
const qk_page = 'page'.bytes()
const qk_category = 'category'.bytes()

fn qint(req request_parser.HttpRequest, key []u8) i64 {
	s := req.get_query_slice(key) or { return 0 }
	return unsafe { tos(&req.buffer[s.start], s.len) }.i64()
}

fn qstr(req request_parser.HttpRequest, key []u8) string {
	s := req.get_query_slice(key) or { return '' }
	return unsafe { tos(&req.buffer[s.start], s.len) }.clone()
}

@[direct_array_access]
fn parse_u_at(s string, start int) i64 {
	mut n := i64(0)
	for i := start; i < s.len; i++ {
		c := s[i]
		if c < `0` || c > `9` {
			break
		}
		n = n * 10 + i64(c - `0`)
	}
	return n
}

fn clamp_count(n i64, max int) int {
	if n < 0 {
		return 0
	}
	if n > max {
		return max
	}
	return int(n)
}

fn body_int(req request_parser.HttpRequest) i64 {
	if req.body.len == 0 {
		return 0
	}
	raw := unsafe { tos(&req.buffer[req.body.start], req.body.len) }
	if te := req.get_header_value_slice('Transfer-Encoding') {
		val := unsafe { tos(&req.buffer[te.start], te.len) }
		if val.contains('chunked') {
			return dechunk(raw).i64()
		}
	}
	return raw.i64()
}

fn dechunk(s string) string {
	mut out := strings.new_builder(s.len)
	mut i := 0
	for i < s.len {
		nl := s.index_after('\r\n', i) or { break }
		size := strconv_hex(s[i..nl])
		if size <= 0 {
			break
		}
		data_start := nl + 2
		out.write_string(s[data_start..data_start + size])
		i = data_start + size + 2
	}
	return out.str()
}

fn strconv_hex(s string) int {
	mut n := 0
	for c in s.trim_space() {
		d := if c >= `0` && c <= `9` {
			int(c - `0`)
		} else if c >= `a` && c <= `f` {
			int(c - `a` + 10)
		} else if c >= `A` && c <= `F` {
			int(c - `A` + 10)
		} else {
			break
		}
		n = n * 16 + d
	}
	return n
}

fn accepts_gzip(req request_parser.HttpRequest) bool {
	ae := req.get_header_value_slice('Accept-Encoding') or { return false }
	return unsafe { tos(&req.buffer[ae.start], ae.len) }.contains('gzip')
}

fn content_type(name string) string {
	ext := name.all_after_last('.')
	return match ext {
		'css' { 'text/css' }
		'js' { 'application/javascript' }
		'json' { 'application/json' }
		'html' { 'text/html' }
		'svg' { 'image/svg+xml' }
		'webp' { 'image/webp' }
		'woff2' { 'font/woff2' }
		else { 'application/octet-stream' }
	}
}

fn static_header(ctype string, size i64) []u8 {
	mut sb := strings.new_builder(96)
	sb.write_string('HTTP/1.1 200 OK\r\nServer: vanilla\r\nContent-Type: ')
	sb.write_string(ctype)
	sb.write_string('\r\nContent-Length: ')
	sb.write_decimal(size)
	sb.write_string('\r\nConnection: keep-alive\r\n\r\n')
	return sb
}

// parse_db_url turns postgres://user:pass@host:port/dbname into a pg_async.ConnConfig.
fn parse_db_url(u string) pg_async.ConnConfig {
	mut s := u
	if s.contains('://') {
		s = s.all_after('://')
	}
	creds := s.all_before('@')
	rest := s.all_after('@')
	host_port := rest.all_before('/')
	mut port := 5432
	if host_port.contains(':') {
		port = host_port.all_after(':').int()
	}
	return pg_async.ConnConfig{
		host:     host_port.all_before(':')
		port:     port
		user:     creds.all_before(':')
		password: creds.all_after(':')
		database: rest.all_after('/')
	}
}

fn main() {
	url := os.getenv_opt('DATABASE_URL') or { 'postgres://bench:bench@localhost:5432/benchmark' }
	cfg := parse_db_url(url)

	// DATABASE_MAX_CONN is the TOTAL connection budget; split it across the
	// thread-per-core workers (each worker owns its own pool, 1..8 connections).
	mut total := (os.getenv_opt('DATABASE_MAX_CONN') or { '64' }).int()
	if total < 1 {
		total = 64
	}
	workers := runtime.nr_cpus()
	mut per_worker := total / workers
	if per_worker < 1 {
		per_worker = 1
	}
	if per_worker > 8 {
		per_worker = 8
	}

	dataset_path := os.getenv_opt('DATASET_PATH') or { '/data/dataset.json' }
	dataset_raw := os.read_file(dataset_path) or { '[]' }
	dataset := json.decode([]DatasetItem, dataset_raw) or { []DatasetItem{} }

	mut prefixes := []string{cap: dataset.len}
	for it in dataset {
		enc := json.encode(it)
		prefixes << enc#[..-1] + ',"total":'
	}

	mut assets := map[string]StaticFile{}
	static_dir := os.getenv_opt('STATIC_DIR') or { '/data/static' }
	for name in os.ls(static_dir) or { []string{} } {
		if name.ends_with('.gz') || name.ends_with('.br') {
			continue
		}
		path := '${static_dir}/${name}'
		fsize := i64(os.file_size(path))
		fd := C.open(&char(path.str), 0)
		if fd < 0 {
			continue
		}
		assets[name] = StaticFile{
			header: static_header(content_type(name), fsize)
			fd:     fd
			size:   fsize
		}
	}

	ro := &Shared{
		dataset:  dataset
		prefixes: prefixes
		assets:   assets
		cache:    map[int][]u8{}
		cache_mu: sync.new_rwmutex()
		gz_cache: map[u64][]u8{}
		gz_mu:    sync.new_rwmutex()
	}

	mut server := http_server.new_server(http_server.ServerConfig{
		port:            8080
		io_multiplexing: .epoll
		limits:          http_server.Limits{
			max_request_bytes: 32 * 1024 * 1024
		}
		async_handler:   handle
		make_state:      fn [ro, cfg, per_worker] () voidptr {
			pool := pg_async.new_pool(cfg, per_worker) or {
				panic('vanilla-epoll: pg pool bring-up failed: ${err}')
			}
			w := &WorkerCtx{
				ro:   ro
				pool: pool
			}
			return voidptr(w)
		}
	})!
	server.run()
}
