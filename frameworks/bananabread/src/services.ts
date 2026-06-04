/**
 * Webservices for the HttpArena workloads, on Seagreen's decorator-based reflection stack.
 */
import {
  ContentType,
  ProviderException,
  type Request,
  type RequestBody,
  type Response,
  ResponseStatus,
} from "../seagreen/src/api/index.ts";
import { StringContent } from "../seagreen/src/modules/io/index.ts";
import {
  FromBody,
  FromContent,
  FromPath,
  FromQuery,
  FromStream,
  Inject,
  ResourceMethod,
  Result,
} from "../seagreen/src/modules/webservices/index.ts";
import * as Data from "./data.ts";
import { type CrudCreateRequest, type CrudUpdateRequest, type DbItem, ListWithCount, type ProcessedItem } from "./model.ts";

/** In-process 200 ms TTL cache for the cached single-item read. */
class TtlCache {
  private readonly map = new Map<number, { body: string; expiresAt: number }>();
  constructor(private readonly ttlMs = 200) {}
  get(id: number): string | undefined {
    const e = this.map.get(id);
    if (!e) return undefined;
    if (e.expiresAt <= performance.now()) {
      this.map.delete(id);
      return undefined;
    }
    return e.body;
  }
  set(id: number, body: string): void {
    this.map.set(id, { body, expiresAt: performance.now() + this.ttlMs });
  }
  invalidate(id: number): void {
    this.map.delete(id);
  }
}
const cache = new TtlCache(200);

export class Baseline {
  @ResourceMethod("GET")
  sum(@FromQuery("a") a: number, @FromQuery("b") b: number): number {
    return a + b;
  }

  @ResourceMethod("POST")
  sumBody(@FromQuery("a") a: number, @FromQuery("b") b: number, @FromBody() c: number): number {
    return a + b + c;
  }
}

export class Upload {
  @ResourceMethod("POST")
  async compute(@FromStream() body: RequestBody): Promise<number> {
    let total = 0;
    for await (const chunk of body.chunks()) total += chunk.length;
    return total;
  }
}

export class JsonService {
  @ResourceMethod("GET", ":count")
  compute(@FromPath("count") count: number, @FromQuery("m") m = 1): ListWithCount<ProcessedItem> {
    if (Data.dataset.length === 0) throw new ProviderException(ResponseStatus.InternalServerError, "No dataset");
    const take = Math.max(0, Math.min(count, Data.dataset.length));
    const items = Data.dataset.slice(0, take).map((d) => ({ ...d, total: d.price * d.quantity * m }));
    return new ListWithCount(items);
  }
}

export class AsyncDatabase {
  @ResourceMethod("GET")
  async compute(@FromQuery("min") min = 10, @FromQuery("max") max = 50, @FromQuery("limit") limit = 50): Promise<ListWithCount<DbItem>> {
    return new ListWithCount(await Data.rangeByPrice(min, max, Math.min(50, Math.max(1, limit))));
  }
}

export class Crud {
  @ResourceMethod("GET")
  async list(@FromQuery("category") category = "electronics", @FromQuery("page") page = 1, @FromQuery("limit") limit = 10) {
    const p = Math.max(1, page);
    const l = Math.min(50, Math.max(1, limit));
    const items = await Data.listByCategory(category, l, (p - 1) * l);
    return { items, total: items.length, page: p, limit: l };
  }

  @ResourceMethod("GET", ":id")
  async get(@FromPath("id") id: number, @Inject() request: Request): Promise<Response> {
    const cached = cache.get(id);
    if (cached !== undefined) {
      return request.respond().content(new StringContent(cached, ContentType.ApplicationJson)).header("X-Cache", "HIT").build();
    }
    const item = await Data.findById(id);
    if (!item) throw new ProviderException(ResponseStatus.NotFound, `Item with ID ${id} does not exist`);
    const json = JSON.stringify(item);
    cache.set(id, json);
    return request.respond().content(new StringContent(json, ContentType.ApplicationJson)).header("X-Cache", "MISS").build();
  }

  @ResourceMethod("POST")
  async create(@FromContent() item: CrudCreateRequest): Promise<Result<DbItem>> {
    await Data.upsert(item);
    cache.invalidate(item.id);
    const created: DbItem = {
      id: item.id,
      name: item.name,
      category: item.category,
      price: item.price,
      quantity: item.quantity,
      active: item.active ?? true,
      tags: item.tags ?? ["bench"],
      rating: { score: 0, count: 0 },
    };
    return new Result(created).status(ResponseStatus.Created);
  }

  @ResourceMethod("PUT", ":id")
  async update(@FromPath("id") id: number, @FromContent() item: CrudUpdateRequest): Promise<DbItem> {
    const ok = await Data.update(id, item);
    cache.invalidate(id);
    if (!ok) throw new ProviderException(ResponseStatus.NotFound, `Item with ID ${id} does not exist`);
    const updated = await Data.findById(id);
    if (!updated) throw new ProviderException(ResponseStatus.NotFound, `Item with ID ${id} does not exist`);
    return updated;
  }
}
