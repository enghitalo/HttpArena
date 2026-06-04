module main

import vanilla.http_server
import vanilla.http_server.http1_1.request_parser
import db.pg
import json
import os
import strings

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

// Item returned by /json — the dataset item plus the computed `total`.
struct OutItem {
	id       i64
	name     string
	category string
	price    i64
	quantity i64
	active   bool
	tags     []string
	rating   Rating
	total    i64
}

struct JsonResp {
	items []OutItem
	count int
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

struct Shared {
mut:
	db      &pg.DB
	dataset []DatasetItem
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
		mut items := []OutItem{cap: count}
		for i in 0 .. count {
			d := sh.dataset[i]
			items << OutItem{
				id:       d.id
				name:     d.name
				category: d.category
				price:    d.price
				quantity: d.quantity
				active:   d.active
				tags:     d.tags
				rating:   d.rating
				total:    d.price * d.quantity * m
			}
		}
		return ok('application/json', json.encode(JsonResp{ items: items, count: items.len }))
	} else if route == '/async-db' {
		return ok('application/json', sh.async_db(qint(req, 'min'), qint(req, 'max'),
			qint(req, 'limit')))
	}
	return ok('text/plain', 'not found')
}

fn (mut sh Shared) async_db(min i64, max i64, limit i64) string {
	mut lim := limit
	if lim < 1 {
		lim = 1
	}
	if lim > 50 {
		lim = 50
	}
	rows := sh.db.exec_param_many('SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN \$1 AND \$2 LIMIT \$3',
		[min.str(), max.str(), lim.str()]) or { return '{"items":[],"count":0}' }
	mut items := []DbItem{cap: rows.len}
	for row in rows {
		items << DbItem{
			id:       row.val(0).int()
			name:     row.val(1)
			category: row.val(2)
			price:    row.val(3).int()
			quantity: row.val(4).int()
			active:   row.val(5) == 't'
			tags:     json.decode([]string, row.val(6)) or { [] }
			rating:   Rating{
				score: row.val(7).i64()
				count: row.val(8).i64()
			}
		}
	}
	return json.encode(DbResp{ items: items, count: items.len })
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

fn main() {
	conninfo := os.getenv_opt('DATABASE_URL') or { 'postgres://bench:bench@localhost:5432/benchmark' }
	mut db := pg.connect_with_conninfo(conninfo, pg.PoolConfig{})!
	if mc := os.getenv_opt('DATABASE_MAX_CONN') {
		db.set_max_open_conns(mc.int())
	}

	dataset_path := os.getenv_opt('DATASET_PATH') or { '/data/dataset.json' }
	dataset_raw := os.read_file(dataset_path) or { '[]' }
	dataset := json.decode([]DatasetItem, dataset_raw) or { []DatasetItem{} }

	mut sh := Shared{
		db:      db
		dataset: dataset
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
