module main

import vanilla.http_server
import vanilla.http_server.http1_1.request_parser
import db.pg
import json
import os
import strings
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

struct DbItem {
	id       int
	name     string
	category string
	price    int
	quantity int
	active   bool
	tags     []string
	rating   Rating
}

struct DbResp {
	items []DbItem
	count int
}

struct Fortune {
	id      int
	message string
}

// A static asset preloaded into memory with its full HTTP response.
struct StaticFile {
	response []u8
}

struct Shared {
mut:
	pool     pg.ConnectionPool
	dataset  []DatasetItem
	prefixes []string // per item: `{…,"total":` (everything but the request-dependent total)
	assets   map[string]StaticFile // /static/<name> -> prebuilt response
}

fn handle(req_buffer []u8, _fd int, mut sh Shared) ![]u8 {
	req := request_parser.decode_http_request(req_buffer)!
	method := unsafe { tos(&req.buffer[req.method.start], req.method.len) }
	target := unsafe { tos(&req.buffer[req.path.start], req.path.len) }
	route := target.all_before('?')

	if route == '/pipeline' {
		return ok('text/plain', 'ok')
	} else if route == '/baseline11' {
		mut sum := qint(req, 'a') + qint(req, 'b')
		if method == 'POST' {
			sum += body_int(req)
		}
		return ok('text/plain', sum.str())
	} else if route == '/upload' {
		return ok('text/plain', req.body.len.str())
	} else if route.starts_with('/json/') {
		count := clamp_count(route[6..].i64(), sh.dataset.len)
		mut m := qint(req, 'm')
		if m == 0 {
			m = 1
		}
		if accepts_gzip(req) {
			// json-comp profile: gzip the body and set Content-Encoding.
			return ok_gzip('application/json', sh.json_body(count, m))
		}
		return sh.json_response(count, m)
	} else if route == '/async-db' {
		return ok('application/json', sh.async_db(qint(req, 'min'), qint(req, 'max'),
			qint(req, 'limit')))
	} else if route == '/fortunes' {
		return ok('text/html; charset=utf-8', sh.fortunes())
	} else if route.starts_with('/static/') {
		if f := sh.assets[route[8..]] {
			return f.response
		}
		return not_found
	}
	return not_found
}

const not_found = 'HTTP/1.1 404 Not Found\r\nServer: vanilla\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

// json_response builds the FULL HTTP response (headers + body) for /json in a
// single allocation — no per-request reflection and no body→response copy.
// Only `total` (price*quantity*m) varies per request; the rest is a precomputed
// prefix. Content-Length is computed up front so everything lands in one buffer.
fn (sh &Shared) json_response(count int, m i64) []u8 {
	mut clen := 21 + digits(i64(count)) // len('{"items":[') + len('],"count":') + '}' + count digits
	if count > 0 {
		clen += count - 1 // item separators
	}
	for i in 0 .. count {
		t := sh.dataset[i].price * sh.dataset[i].quantity * m
		clen += sh.prefixes[i].len + digits(t) + 1 // prefix + total + '}'
	}
	mut sb := strings.new_builder(clen + 96)
	sb.write_string('HTTP/1.1 200 OK\r\nServer: vanilla\r\nContent-Type: application/json\r\nContent-Length: ')
	sb.write_decimal(i64(clen))
	sb.write_string('\r\nConnection: keep-alive\r\n\r\n{"items":[')
	for i in 0 .. count {
		if i > 0 {
			sb.write_u8(`,`)
		}
		sb.write_string(sh.prefixes[i])
		sb.write_decimal(sh.dataset[i].price * sh.dataset[i].quantity * m)
		sb.write_u8(`}`)
	}
	sb.write_string('],"count":')
	sb.write_decimal(i64(count))
	sb.write_u8(`}`)
	return sb
}

// json_body builds just the /json body string (used for the gzip path).
fn (sh &Shared) json_body(count int, m i64) string {
	mut sb := strings.new_builder(count * 224 + 32)
	sb.write_string('{"items":[')
	for i in 0 .. count {
		if i > 0 {
			sb.write_u8(`,`)
		}
		sb.write_string(sh.prefixes[i])
		sb.write_decimal(sh.dataset[i].price * sh.dataset[i].quantity * m)
		sb.write_u8(`}`)
	}
	sb.write_string('],"count":')
	sb.write_decimal(i64(count))
	sb.write_u8(`}`)
	return sb.str()
}

// fortunes queries the fortune table, appends the runtime row, sorts by message
// and renders the HTML table (escaped). 199 seeded + 1 runtime + header = 201 <tr>.
fn (mut sh Shared) fortunes() string {
	mut fortunes := []Fortune{}
	mut conn := sh.pool.acquire() or {
		return '<!doctype html><html><body><table></table></body></html>'
	}
	rows := conn.exec_param_many('SELECT id, message FROM fortune', []) or { [] }
	sh.pool.release(conn)
	for row in rows {
		fortunes << Fortune{
			id:      nn(row.vals[0]).int()
			message: nn(row.vals[1])
		}
	}
	fortunes << Fortune{
		id:      0
		message: 'Additional fortune added at request time.'
	}
	fortunes.sort(a.message < b.message)
	mut sb := strings.new_builder(32768)
	sb.write_string('<!doctype html><html><head><title>Fortunes</title></head><body><table><tr><th>id</th><th>message</th></tr>')
	for f in fortunes {
		sb.write_string('<tr><td>')
		sb.write_decimal(i64(f.id))
		sb.write_string('</td><td>')
		sb.write_string(escape_html(f.message))
		sb.write_string('</td></tr>')
	}
	sb.write_string('</table></body></html>')
	return sb.str()
}

fn escape_html(s string) string {
	return s.replace_each(['&', '&amp;', '<', '&lt;', '>', '&gt;', '"', '&quot;', "'", '&apos;'])
}

// digits returns the number of decimal digits in a non-negative integer.
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

fn (mut sh Shared) async_db(min i64, max i64, limit i64) string {
	mut lim := limit
	if lim < 1 {
		lim = 1
	}
	if lim > 50 {
		lim = 50
	}
	mut conn := sh.pool.acquire() or { return '{"items":[],"count":0}' }
	rows := conn.exec_param_many('SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN \$1 AND \$2 LIMIT \$3',
		[min.str(), max.str(), lim.str()]) or {
		sh.pool.release(conn)
		return '{"items":[],"count":0}'
	}
	sh.pool.release(conn)
	mut items := []DbItem{cap: rows.len}
	for row in rows {
		items << DbItem{
			id:       nn(row.vals[0]).int()
			name:     nn(row.vals[1])
			category: nn(row.vals[2])
			price:    nn(row.vals[3]).int()
			quantity: nn(row.vals[4]).int()
			active:   nn(row.vals[5]) == 't'
			tags:     json.decode([]string, nn3(row.vals[6], '[]')) or { [] }
			rating:   Rating{
				score: nn(row.vals[7]).i64()
				count: nn(row.vals[8]).i64()
			}
		}
	}
	return json.encode(DbResp{ items: items, count: items.len })
}

// nn unwraps a nullable column value to a plain string ('' for NULL).
@[inline]
fn nn(v ?string) string {
	return v or { '' }
}

// nn3 unwraps a nullable column value with a custom default.
@[inline]
fn nn3(v ?string, d string) string {
	return v or { d }
}

// qint reads a query parameter as an integer (0 if absent / non-numeric).
fn qint(req request_parser.HttpRequest, key string) i64 {
	s := req.get_query_slice(key.bytes()) or { return 0 }
	return unsafe { tos(&req.buffer[s.start], s.len) }.i64()
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

// body_int parses the request body as an integer, decoding chunked transfer
// encoding when present.
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

// dechunk decodes an HTTP/1.1 chunked body into its payload.
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
		i = data_start + size + 2 // skip data + trailing CRLF
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

// ok builds a complete HTTP/1.1 response with the given content type.
fn ok(ctype string, body string) []u8 {
	mut sb := strings.new_builder(body.len + 96)
	sb.write_string('HTTP/1.1 200 OK\r\nServer: vanilla\r\nContent-Type: ')
	sb.write_string(ctype)
	sb.write_string('\r\nContent-Length: ')
	sb.write_decimal(i64(body.len))
	sb.write_string('\r\nConnection: keep-alive\r\n\r\n')
	sb.write_string(body)
	return sb
}

// ok_gzip gzip-compresses the body and sets Content-Encoding: gzip.
fn ok_gzip(ctype string, body string) []u8 {
	gz := gzip.compress(body.bytes()) or { return ok(ctype, body) }
	mut sb := strings.new_builder(gz.len + 128)
	sb.write_string('HTTP/1.1 200 OK\r\nServer: vanilla\r\nContent-Encoding: gzip\r\nContent-Type: ')
	sb.write_string(ctype)
	sb.write_string('\r\nContent-Length: ')
	sb.write_decimal(i64(gz.len))
	sb.write_string('\r\nConnection: keep-alive\r\n\r\n')
	unsafe { sb.write_ptr(gz.data, gz.len) }
	return sb
}

// accepts_gzip reports whether the request advertises gzip in Accept-Encoding.
fn accepts_gzip(req request_parser.HttpRequest) bool {
	ae := req.get_header_value_slice('Accept-Encoding') or { return false }
	return unsafe { tos(&req.buffer[ae.start], ae.len) }.contains('gzip')
}

// content_type maps a file extension to a MIME type for the static handler.
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

// parse_db_url turns postgres://user:pass@host:port/dbname into a pg.Config.
fn parse_db_url(u string) pg.Config {
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
	return pg.Config{
		host:     host_port.all_before(':')
		port:     port
		user:     creds.all_before(':')
		password: creds.all_after(':')
		dbname:   rest.all_after('/')
	}
}

fn main() {
	url := os.getenv_opt('DATABASE_URL') or { 'postgres://bench:bench@localhost:5432/benchmark' }
	mut size := (os.getenv_opt('DATABASE_MAX_CONN') or { '64' }).int()
	if size < 1 {
		size = 64
	}
	if size > 200 {
		size = 200 // leave headroom under Postgres max_connections
	}
	mut pool := pg.new_connection_pool(parse_db_url(url), size)!

	dataset_path := os.getenv_opt('DATASET_PATH') or { '/data/dataset.json' }
	dataset_raw := os.read_file(dataset_path) or { '[]' }
	dataset := json.decode([]DatasetItem, dataset_raw) or { []DatasetItem{} }

	// Precompute each item's JSON prefix once: `{…,"rating":{…},"total":`
	// (drop the closing brace, append the total key). Only the total value is
	// request-dependent, so the hot path never serializes a struct.
	mut prefixes := []string{cap: dataset.len}
	for it in dataset {
		enc := json.encode(it)
		prefixes << enc#[..-1] + ',"total":'
	}

	// Preload static assets into memory as ready-to-send responses (originals
	// only; skip the precompressed .gz/.br siblings — we serve identity).
	mut assets := map[string]StaticFile{}
	static_dir := os.getenv_opt('STATIC_DIR') or { '/data/static' }
	for name in os.ls(static_dir) or { []string{} } {
		if name.ends_with('.gz') || name.ends_with('.br') {
			continue
		}
		bytes := os.read_bytes('${static_dir}/${name}') or { continue }
		assets[name] = StaticFile{
			response: static_response(content_type(name), bytes)
		}
	}

	mut sh := Shared{
		pool:     pool
		dataset:  dataset
		prefixes: prefixes
		assets:   assets
	}

	mut server := http_server.new_server(http_server.ServerConfig{
		port:            8080
		io_multiplexing: .epoll
		request_handler: fn [mut sh] (req_buffer []u8, fd int) ![]u8 {
			return handle(req_buffer, fd, mut sh)
		}
	})!
	server.run()
}

// static_response prebuilds the full HTTP response for a static file.
fn static_response(ctype string, body []u8) []u8 {
	mut sb := strings.new_builder(body.len + 96)
	sb.write_string('HTTP/1.1 200 OK\r\nServer: vanilla\r\nContent-Type: ')
	sb.write_string(ctype)
	sb.write_string('\r\nContent-Length: ')
	sb.write_decimal(i64(body.len))
	sb.write_string('\r\nConnection: keep-alive\r\n\r\n')
	unsafe { sb.write_ptr(body.data, body.len) }
	return sb
}
