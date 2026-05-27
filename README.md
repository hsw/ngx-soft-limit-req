# ngx_http_soft_limit_req_module

A dynamic nginx/Angie module: a **tag-don't-reject** rate limiter. It runs the stock
`limit_req` leaky-bucket math but, on overflow, **never rejects** — instead it writes a
per-directive variable (`"1"` / `""`). A `map` + `proxy_pass http://$pool` then reroutes
over-cap ("grey") traffic to a separate upstream, while a stock `limit_req` keeps hard-
blocking abusive IPs **in the same location**.

> Status: **implemented** and integration-tested against pinned **nginx 1.31.1** (current
> mainline) on **Ubuntu 24.04** — 16 checks (5 harness + 11 behavior cases).

## Why

During an L7 flood the per-host aggregate RPS blows past organic peak. We want to shed the
excess to a sacrificial/challenge pool **without** returning errors to legit under-cap
users. Stock `limit_req` can only reject; `limit_req_dry_run` is per-location (can't mix
hard-reject on one zone with tag-only on another) and exposes a single `$limit_req_status`.
This module gives each directive its own verdict variable, evaluates every zone every
request, and never rejects.

> **Do you need this module?** If you only need to *tag a single zone* (and don't mix it with
> a hard-rejecting zone in the same location), stock nginx already suffices: `limit_req` with
> `limit_req_dry_run on;` accounts without rejecting and sets `$limit_req_status`
> (`PASSED`/`DELAYED`/`REJECTED`), which you can feed into a `map`. Reach for `soft_limit_req`
> when you need **per-zone verdicts**, **hard-reject and tag-only zones together in one
> location**, or a guaranteed **never-reject** path.

## Directives

```nginx
soft_limit_req_zone <key> zone=NAME:SIZE rate=Nr/s;     # http{}, same as stock limit_req_zone
soft_limit_req zone=NAME [burst=N] [set=$var];          # server/location
```

- `rate=` accepts `Nr/s` or `Nr/m` (requests per second or per minute), same as stock
  `limit_req_zone`. `30r/m` is internally `0.5r/s`.

- `burst=` is **optional** and defaults to `0` (same as stock `limit_req`): with no burst the
  verdict flips to `"1"` as soon as the smoothed rate exceeds `rate=`. Give it a non-zero value
  to allow a short spike before tagging.

- `set=$var` — target variable, written per request in the PREACCESS phase. The handler
  writes `"1"` when the bucket is over `burst`, and `""` otherwise — including the
  under-budget path, the empty-key (verified-bypass) path, and an oversized key. So `""`
  means "not over" and routes to `main`. `set=` is optional; omit it to run the bucket
  without writing a variable. For a `map`, `""` (and `"0"`) read as false. If the location
  has no `soft_limit_req` (handler never ran) the variable reads as not-found/empty.
- Multiple `soft_limit_req` directives each write their **own** variable independently —
  every zone is evaluated on every request (no break on the first overflow).

> **Reserved name:** `$__soft_limit_req_seen` is an internal variable name reserved by this
> module (it backs the redirect-surviving once-per-request accounting marker). Do **not**
> define or reference it in your configuration. The `set=$var` parser already rejects it
> (case-insensitively), but nginx has a single shared variable namespace, so any other
> variable-producing directive — `set`, `map`, `geo`, a `*_set` directive, etc. — that
> predeclares this exact name would alias the guard slot and corrupt accounting across
> internal redirects. Avoiding the name is the supported mitigation.

## Usage — stock IP hard-block + soft host tag → upstream, in one location

The canonical shape, and what the module exists for: **stock `limit_req` hard-rejects
abusive IPs**, while **`soft_limit_req` tags hosts that are over their cap** and a `map`
reroutes that "grey" traffic to a separate **upstream** — all in the same `location`,
without ever returning an error to legit under-cap users.

```nginx
limit_req_zone      $binary_remote_addr zone=perip:32m   rate=50r/s;    # stock: hard reject
soft_limit_req_zone $host               zone=perhost:64m rate=12000r/s; # soft: tag only

map $over_host $pool {            # http{} only; read lazily at proxy_pass (content phase)
    "1"     grey_pool;            # host over its cap → reroute
    default main;                 # under cap → normal upstream
}

upstream main      { server 10.0.0.1:80; }
upstream grey_pool { server 10.0.0.2:80; }   # sacrificial / challenge tier

location / {
    limit_req      zone=perip   burst=100  nodelay;        # STOCK: 503s abusive IPs
    soft_limit_req zone=perhost burst=2000 set=$over_host; # TAG: "1"/"" → $over_host
    proxy_pass http://$pool;                               # main | grey_pool
}
```

A request is hard-rejected (503) only if its **IP** trips `perip`. Otherwise it is always
served — but if its **$host** is over `perhost`, `$over_host` becomes `"1"` and the `map`
sends it to `grey_pool` instead of `main`. To tag on more than one signal, add more
`soft_limit_req` directives (each with its own `set=$var`) — every zone is evaluated on
every request.

### Caveat: use `map`, not `if`

The variable is set in the **PREACCESS** phase. Consume it in a **`map`** (lazy — read at
`proxy_pass` in the content phase). **Do not** use it in `if`/`return` at `location`/`server`
level — that is the **rewrite** phase, which runs *before* preaccess, so the variable is
still empty there. To hard-reject on a soft signal, route via `map` to a dead-end pool.

### Notes

- Value is the binary flag `"1"` / `""`. Magnitude (`excess`) is **not** exposed — it
  saturates near `burst`. For tiered routing use **stepped zones**, each with its own
  `set=$var`.
- Key the stock IP zone on the **real client IP** (after `realip`), not the CDN/proxy address.
- A verified-bypass HMAC cookie can map to an empty key on the soft host zone so reroute never
  bites verified users; the IP hard-block still applies.

## Limitations & semantics

Known, intentional behaviors — design choices for a tag-don't-reject router, not bugs:

- **Once-per-request accounting is request-wide, not per-zone.** A request is accounted by the
  **first** location whose `soft_limit_req` does a real lookup; if that location then
  *internally redirects* (e.g. `try_files $uri @app`) to a target carrying a **different**
  zone, the target's limiter is **skipped** and its `set=$var` is left unset. The marker
  exists to stop double-counting the same request across the redirect. **Recommendation:** put
  all `soft_limit_req` directives for a request in **one** location (the entry, or the final
  redirect target) rather than splitting different zones across a redirect chain.
  Redirect-target-*only* limiters (limiter on `@app` but not on the entry) work fine — that
  common `try_files` shape is covered by case `81`.

- **Subrequests are not tagged or accounted.** Only the main request runs the handler
  (`r == r->main`). `auth_request` / mirror / SSI subrequests neither write a verdict variable
  nor charge a bucket. This differs from stock `limit_req` (which gates on
  `r->main->limit_req_status`) and is deliberate: an internal helper request should not flip
  routing verdicts or skew the bucket.

- **Order vs stock `limit_req` in the same location is not pinned.** Both register
  PREACCESS-phase handlers; the relative order follows module load order. A request
  hard-rejected by stock `limit_req` (503) may or may not also charge the soft bucket,
  depending on which handler ran first. For routing this is harmless (a rejected request is
  gone either way), but do not rely on the soft bucket reflecting hard-rejected traffic.

- **Over-budget accounting mirrors stock `limit_req`.** Once a bucket crosses `burst`, the
  request is tagged but stored excess / `last` are **not** advanced further (same as stock,
  which rejects at that point). Sustained accepted overload therefore does not accumulate
  unbounded "debt"; the bucket drains by wall-clock time from the last under-budget request, so
  a flooded host stays grey while letting a thin trickle through to `main`. This is the
  intended, stock-faithful behavior, not a leak.

- **Over-limit logging is at `info` level.** Going over budget is the normal hot path for this
  module, so it is logged at `NGX_LOG_INFO` (silent at the default `error` log level) rather
  than `error`, to avoid self-inflicted log amplification under flood. Lower `error_log` to
  `info` to observe soft-limiting. There is no `soft_limit_req_log_level` directive yet.

## Build

Dynamic module, built against the target nginx (or Angie) source:

```sh
./configure --add-dynamic-module=/path/to/ngx-soft-limit-req --with-compat
make modules
# then in nginx.conf:
load_module modules/ngx_http_soft_limit_req_module.so;
```

`--with-compat` is required so the `.so` is binary-compatible with the running server. The
module itself depends only on core HTTP — it does **not** require `--with-http_realip_module`
or any other optional module. (The test harness builds with `--with-http_realip_module`
only so the integration cases can vary the per-IP key via `X-Forwarded-For`; the soft module
does not need it.)

### Version compatibility

Built and integration-tested against **nginx 1.31.1** (current mainline) on **Ubuntu 24.04**,
pinned in the test harness via the `NGINX_VERSION` build ARG. The module is a fork of nginx's
own `ngx_http_limit_req_module.c` and uses only the stable core HTTP module ABI, so it builds
against both nginx and Angie; rebuild the `.so` against whatever version the production fleet
runs and keep `--with-compat` matching. **Other versions/distros are not part of the automated
gate** — the verified target is the one above; treat anything else as needing its own rebuild
and re-test.

The Docker test harness (`test/`) pins the nginx version and builds the `.so` automatically.

## Testing

No C unit-test framework — the suite is Docker + curl/load (bash). It builds the `.so`
against pinned nginx, boots a container, and runs every `test/cases/*.sh`. Run:

```sh
./test/run.sh
```

Checks: 5 harness checks (`.so` built, `nginx -t` syntax + module load, server up,
`GET /` → 200) plus 11 behavior cases — zone + directive parsing (`10`, both
`soft_limit_req_zone` and the `soft_limit_req` location directive), never-rejects under flood
with the verdict actually flipping to `1` (`20`), single + multi `set=$var` (`30`/`31`), stock
IP hard-block coexisting with soft host routing via `map` plus the negative `if` phase-order
assertion (`40`), shm-stability soak (`50`), empty-key verified-bypass (`60`), zone-full /
alloc-failure graceful degradation (`70`), and the internal-redirect accounting cases —
same-zone re-entry counted once (`80`), redirect-target-only limiter accounts (`81`), and
bypass-entry-then-redirect-target (`82`). The config snippets above mirror
`test/conf/nginx.conf`.

Empty-verdict assertions emit the header as `add_header X-Over "v=$over_host" always` so a
present-but-empty verdict reads `v=` and is distinguishable from an absent header (nginx drops
empty-value headers).

**Inspection-only gaps** (not curl-testable): the oversized-key guard (`key.len > 65535`
skips the zone) cannot be exercised because curl cannot send a >64 KB single header/key value;
the clock-skew millisecond clamp (`ms < -60000 → 1`, `ms < 0 → 0` in `*_lookup`) needs a
backward wall-clock jump that the test harness cannot induce; and a key-evaluation failure
(`ngx_http_complex_value` returning non-`NGX_OK`, an allocation-failure path) now **fails open**
— it logs `soft_limit_req: failed to evaluate key, skipping zone`, leaves that directive's
verdict `""`, does not account the zone, and continues, so it never returns 500 and never
rejects. These are verified by code inspection only; the first two are ported verbatim from
stock `limit_req`.

### Static analysis, sanitizers & coverage (local)

In addition to the integration suite, the repo ships Docker-based analysis tools (under
`test/`, results land in `tmp/`). These are **manual local gates** — run them before a
release; CI does not (to keep CI fast). Each builds nginx + the module and exits non-zero on a
real finding in the module's own source:

```sh
bash test/sast.sh        # 5 static analyzers in parallel: scan-build, clang-tidy,
                         # cppcheck, gcc-fanalyzer, flawfinder (scan-build advisory)
bash test/asan.sh        # AddressSanitizer + UBSan build, runs the cases, scans for findings
bash test/valgrind.sh    # Valgrind memcheck over a case subset (leak / invalid-access gate)
bash test/coverage.sh    # gcov line/branch coverage of the module
```

Current status on the module source: SAST clean (only advisory style/bugprone notes), **0
ASan/UBSan findings**, **0 Valgrind leaks/errors** (beyond tightly-anchored nginx-core
init-pool suppressions), and **~77% line / ~88% branch** coverage from the HTTP cases (the
uncovered remainder is config-parse error branches, which the dynamic-build integration
harness exercises instead, plus a few rbtree-rebalance / reload edge paths).

### Continuous integration

`.github/workflows/test.yml` runs on every push / PR: it lints the workflows (actionlint) and
runs `./test/run.sh` (build nginx + module, full integration suite). SAST / ASan / Valgrind /
coverage are intentionally **not** in CI — they are the manual local gates above.

## License

BSD 2-Clause. This module is a derivative work of nginx's
`ngx_http_limit_req_module.c`; the original nginx copyright is retained as
required. See [LICENSE](LICENSE). Source files reusing nginx code must keep the
nginx BSD copyright header.
