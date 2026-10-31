# Weather Forecast

A small Ruby on Rails app: enter an address and get the current temperature, today's high/low and a 7-day forecast. Forecasts are cached by zip code for 30 minutes, and the page shows whether a result came from the cache.

- **Ruby** 3.3 · **Rails** 8.1 · no database
- **Geocoding:** [Nominatim / OpenStreetMap](https://nominatim.org/release-docs/latest/api/Search/)
- **Weather:** [Open-Meteo](https://open-meteo.com/en/docs)
- **Cache:** `Rails.cache`, backed by Redis in Docker/production

Both APIs are free and keyless, so there's nothing to configure.

## Running it

### Docker (app + Redis)

```sh
docker compose up --build
open http://localhost:3000
```

If port 3000 is taken, run `PORT=3456 docker compose up --build` instead.

### Locally

```sh
bundle install
bin/rails server            # uses an in-memory cache
REDIS_URL=redis://localhost:6379/0 bin/rails server   # or use a local Redis
```

### Tests and checks

```sh
bin/rails test     # Minitest + WebMock, no real network calls
bin/rubocop        # rubocop-rails-omakase
bin/brakeman       # static security scan
bin/bundler-audit  # known-vulnerable gems
bin/ci             # all of the above
```

CI (`.github/workflows/ci.yml`) runs Brakeman, bundler-audit, RuboCop and the tests, smoke-tests the Redis cache store, and boots the app with `docker compose` and checks `/up`.

## How it works

```
GET /?address=...
  └─ ForecastsController#index
       └─ ForecastService#call(address)
            ├─ geocode(address)        Nominatim → zip, country, lat/lon   (cached 1 day by address)
            └─ Rails.cache.fetch("forecast/v1/<country>/<zip>", expires_in: 30.minutes)
                 └─ fetch_forecast     Open-Meteo → current, high/low, 7 days
```

| File | Purpose |
| --- | --- |
| `app/services/forecast_service.rb` | All third-party calls, parsing, caching and error handling |
| `app/controllers/forecasts_controller.rb` | Reads `address`, calls the service, maps errors to 422 / 503 |
| `app/views/forecasts/index.html.erb` | Form, forecast and the **Live** / **From cache** badge |
| `test/services/forecast_service_test.rb` | Happy path, caching/expiry and failure cases |
| `test/controllers/forecasts_controller_test.rb` | End-to-end request tests with stubbed HTTP |

**Cache indicator.** The block passed to `Rails.cache.fetch` only runs on a miss, so the service sets `cached = false` inside it. The cached value also stores `fetched_at`, which the page shows as "fetched N minutes ago".

**Error handling.** HTTP uses `Net::HTTP` with `open_timeout` (3s) and `read_timeout` (5s). Timeouts, DNS/connection errors, TLS errors, 429s, non-2xx responses, invalid JSON and unexpected payload shapes are all turned into `ForecastService::Error` with a message that's safe to show. Bad input (blank, too long, not found, no zip code) raises `ForecastService::InvalidAddress`. The controller renders those as 503 and 422 with the form still filled in. An upstream problem never turns into a 500, and a failed lookup is never cached.

## Design decisions and trade-offs

**Keyless providers.** Nominatim and Open-Meteo need no sign-up, so reviewers can run the app immediately. The cost: Nominatim's public instance allows about 1 request/second and expects a descriptive `User-Agent` (configurable via `FORECAST_USER_AGENT`). Its free-text matching is also weaker than commercial geocoders' (e.g. "350 Fifth Avenue, New York, NY 10118" can resolve to a 5th Avenue in Pelham, NY), which is why the page always shows the resolved location and zip. At real scale I'd switch to a paid geocoder or self-host Nominatim. The service is the only place that knows about the providers, so that change stays local.

**Cache key = country + zip.** The requirement is to cache by zip code, so every address in a zip shares one forecast. That trades some precision (a large zip can span a few km) for a much higher hit rate. The country is part of the key because postcodes aren't unique worldwide. The `v1` prefix lets me change the cached shape later without reading stale formats. If an address has no postcode (some rural or non-US places), I return a clear message instead of guessing a key.

**Geocoding is cached too (1 day).** An address's location doesn't change, Nominatim's policy asks clients to cache, and caching it makes the cached forecast path make zero external calls. The key is a SHA-256 of the normalized address, so raw addresses don't sit in Redis keys.

**Cached values are plain hashes**, not custom objects, so a deploy can't break deserializing entries that are already in Redis.

**No database.** Nothing needs to be durable, so I skipped Active Record. The app is stateless and the only backing service is Redis.

**Synchronous fetch on a miss.** It's the simplest correct design. The worst case is bounded by the timeouts (about 16s across two calls on a miss), and the cost is that a slow upstream occupies a Puma thread for that long.

### Cache eviction

- **TTL:** forecasts expire 30 minutes after they're fetched (`expires_in: 30.minutes`), and geocodes after 1 day. Redis expires keys itself, so there's no cleanup job. (The Redis-level TTL is 35 minutes because Rails adds a 5-minute grace period for `race_condition_ttl`, but Rails treats the entry as expired after 30.)
- **Memory bound:** the Docker Redis runs with `maxmemory 64mb` and `maxmemory-policy allkeys-lru`. When it's full, the least-recently-used entries go first, which suits a cache where popular zip codes stay hot. Persistence is disabled because losing the cache only costs extra API calls.
- **Redis outage:** the production store has short timeouts and an `error_handler` that logs and treats failures as cache misses. The app slows down (every request goes upstream) but keeps working. I verified this by stopping the Redis container: requests still return 200.
- Without `REDIS_URL` the app falls back to `:memory_store` (per process, bounded at 32MB by default, LRU).

### Concurrency and scaling

- **Stateless app servers.** All shared state lives in Redis, so Puma processes and containers scale horizontally behind a load balancer, and every instance sees the same cache. (With `:memory_store`, each process would have its own cache, which is why Redis is used in Docker/production.)
- **Thread safety.** The service keeps no shared mutable state: one instance per request, constants are frozen, and `Net::HTTP` connections are per call. Puma's default 3 threads per process can serve concurrent requests safely.
- **Cache stampede.** When a popular key expires, `race_condition_ttl: 10.seconds` lets one request refresh it while others briefly keep getting the slightly stale value, instead of all hitting Open-Meteo at once. This narrows the stampede window but doesn't eliminate it; a cold key can still be fetched by several requests at once. A distributed lock would fully fix it, but isn't worth the complexity here.
- **Bounded waiting.** Timeouts cap how long a thread can be blocked by an upstream, so a slow provider can't use up the worker pool indefinitely.

### What I'd add for heavy production traffic

- A circuit breaker (e.g. `stoplight`) so a provider that is down fails fast instead of every request waiting out the timeout.
- Retries with backoff for idempotent GETs, background refresh of hot keys before they expire, and stale-on-error (serve the last good forecast when the upstream is down).
- Per-client rate limiting (Rails' built-in `rate_limit` or `rack-attack`) to protect the upstream quotas.
- Metrics for cache hit ratio, upstream latency and error rates, plus structured logs and error tracking.
- A JSON API endpoint if other clients need the data.
