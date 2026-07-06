# ngx_http_soft_limit_req_module

A dynamic nginx/Angie module: a **tag-don't-reject** rate limiter. It runs the stock
`limit_req` leaky-bucket math but, on overflow, **never rejects** — instead it writes a
per-directive variable (`"1"` / `""`). A `map` + `proxy_pass http://$pool` then reroutes
over-cap ("grey") traffic to a separate upstream, while a stock `limit_req` keeps hard-
blocking abusive IPs **in the same location**.

> Status: **implemented** and integration-tested against pinned **nginx 1.31.1** (current
> mainline) on **Ubuntu 24.04** — 23 checks (5 harness + 18 behavior cases).

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
soft_limit_req zone=NAME [burst=N] [set=$var];          # server/location  (PREACCESS)
soft_limit_req_server zone=NAME [burst=N] [set=$var];   # http/server      (POST_READ)
```

- `rate=` accepts `Nr/s` or `Nr/m` (requests per second or per minute), same as stock
  `limit_req_zone`. `30r/m` is internally `0.5r/s`.

- `burst=` is **optional** and defaults to `0` (same as stock `limit_req`): with no burst the
  verdict flips to `"1"` as soon as the smoothed rate exceeds `rate=`. Give it a non-zero value
  to allow a short spike before tagging.

- `set=$var` — target variable, written once per request. The phase depends on which
  directive sets it: `soft_limit_req` writes it in PREACCESS, `soft_limit_req_server` writes
  it in POST_READ (see the [`soft_limit_req_server`](#soft_limit_req_server--verdict-in-the-rewrite-phase-post_read)
  section). The handler
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
still empty there. Everything from the ACCESS phase onward — access-phase modules, precontent
`try_files`, the content-phase `map`, `access_log` — does see it; only rewrite-phase consumers
do not. To hard-reject on a soft signal, route via `map` to a dead-end pool.

### Notes

- Value is the binary flag `"1"` / `""`. Magnitude (`excess`) is **not** exposed — it
  saturates near `burst`. For tiered routing use **stepped zones**, each with its own
  `set=$var`.
- Key the stock IP zone on the **real client IP** (after `realip`), not the CDN/proxy address.
- A verified-bypass HMAC cookie can map to an empty key on the soft host zone so reroute never
  bites verified users; the IP hard-block still applies.

## `soft_limit_req_server` — verdict in the rewrite phase (POST_READ)

```nginx
soft_limit_req_server zone=NAME [burst=N] [set=$var];   # http{} / server{}
```

`soft_limit_req_server` runs the **same** leaky-bucket accounting against the **same**
`soft_limit_req_zone` shared zones, but emits its verdict in the **POST_READ** phase —
*before* the **REWRITE** phase. That makes `set=$var` readable by rewrite-phase directives
(`if`, `rewrite`, `set`), by precontent-phase `try_files`, and by an early `access_log` — not
only by the lazy content-phase `map` → `proxy_pass` pattern. (All of these run after
POST_READ, so the verdict is already set by the time they evaluate it.)

This is the positive counterpart to the [`map`, not `if`](#caveat-use-map-not-if) caveat:
the location-level `soft_limit_req` writes its verdict in PREACCESS, which runs *after* the
rewrite phase, so `if ($over_host) return 444;` never sees it. `soft_limit_req_server` writes
the verdict early enough for `if`/`return` to fire.

### How it differs from location-level `soft_limit_req`

| | `soft_limit_req` | `soft_limit_req_server` |
|---|---|---|
| phase | PREACCESS | POST_READ (earlier) |
| scope | `server{}` / `location{}` | `http{}` / `server{}` (not `location{}`) |
| verdict readable in | ACCESS phase onward: access, precontent (`try_files`), content (`map`), log — **not** the rewrite phase | rewrite phase (`if`/`rewrite`), precontent (`try_files`) **and** content phase |
| per-location rates | yes | no — there is no matched location yet at POST_READ |

Everything else is identical: it reuses the zones declared by `soft_limit_req_zone`, never
rejects, writes `"1"` when the bucket is over `burst` and `""` otherwise (including the
empty-key / oversized-key / eval-failure bypass paths), and evaluates every configured zone
on every request. `burst=` and `set=$var` behave exactly as for `soft_limit_req`.

It is **not** allowed in `location{}`: POST_READ runs before any location is matched, so a
per-location placement would have no meaning. Place it in `server{}`, or in `http{}` to apply
it to **all** servers — an `http`-level `soft_limit_req_server` is inherited by every server
that does not declare its own (a server that declares any `soft_limit_req_server` of its own
overrides the inherited set entirely, same inheritance rule as other server-scoped lists).

### Key-readiness constraint (important)

Because the verdict is computed in POST_READ, the **zone key variable must already resolve at
POST_READ**. If the key evaluates empty (or oversized, or fails to evaluate), that zone is
**silently skipped** — no charge, verdict left `""`. There is no runtime error; the limiter
just becomes a no-op, which is easy to misread as "under budget".

- **POST_READ-safe keys:** `$host`, `$http_*` (any request header). Use these. They resolve
  from the request line/headers, are stable across phases, and are **realip-independent** — so
  evaluating them at POST_READ neither reads a phase-sensitive value nor disturbs any other
  consumer.
- **Do NOT key on `$remote_addr` (or any cacheable, realip-affected / late-bound variable) —
  it POISONS that variable for the whole request.** Two problems compound here:
  1. **Wrong value at POST_READ.** `ngx_http_realip_module` also runs in POST_READ, and this
     module's handler runs **before** realip's, so when `soft_limit_req_server` evaluates
     `$remote_addr` it is still the **raw TCP peer** (your CDN/LB address), *not* the rewritten
     client IP — even with a global `set_real_ip_from`. The order is fixed by nginx internals:
     postconfiguration runs in module order and an `--add-dynamic-module` module is appended
     last, so it pushes its POST_READ handler after realip; the phase engine then flattens
     POST_READ handlers in reverse push order, so the last-pushed (ours) runs first.
  2. **Cache poisoning of the whole request (the real footgun).** `$remote_addr` is a
     **cacheable** variable (its get_handler sets `no_cacheable = 0`). Our key is a compiled
     complex value, evaluated via the *indexed* (caching) variable path, so the first read
     populates and caches `r->variables[$remote_addr]` with the **raw peer**. realip later
     rewrites only `r->connection->addr_text`/`sockaddr` — it does **not** invalidate that
     variable cache. So every *subsequent* `$remote_addr` read in the same request —
     `proxy_set_header X-Real-IP`, access-log `$remote_addr`, `map $remote_addr …`, the
     PREACCESS `soft_limit_req` / stock `limit_req` — also sees the stale **raw peer**, not the
     realip client IP. Keying a `soft_limit_req_server` zone on `$remote_addr` therefore
     silently corrupts logging, headers, maps, and downstream limiters for the entire request.
     This is action-at-a-distance and very hard to debug.
  - **What to do instead:** for a server-scope `soft_limit_req_server` zone, key on `$host` /
    `$http_*` (stable, realip-independent, no poisoning) — **never** `$remote_addr`, global
    realip or not. Because this module's POST_READ handler runs *before* realip's POST_READ
    pass (see above), a server-scope zone always reads the **raw peer** at POST_READ *and*
    poisons `$remote_addr` for the rest of the request; configuring realip globally does **not**
    change that. Per-real-client-IP limiting on `$remote_addr` belongs in a **PREACCESS /
    location-level** limiter (location-level `soft_limit_req`, or stock `limit_req`), and even
    there it is reliable **only when `set_real_ip_from` / `real_ip_header` are configured at
    `http{}` or `server{}` level** (global). At that scope realip's **POST_READ** pass rewrites
    the address before the *PREACCESS* limiter reads its key: realip's POST_READ handler
    resolves `r->loc_conf` to the server's default location, finds `rlcf->from` set, and
    rewrites `$remote_addr` then — so by the time a PREACCESS limiter evaluates the key it is
    already the client IP, and the cache is populated with the correct value. **If realip is
    configured only inside a `location{}`**, even a location-level `soft_limit_req` is *not*
    safe: realip's POST_READ pass sees no inherited config (`rlcf->from == NULL`, no location
    matched yet) and does nothing, and realip only rewrites in its **PREACCESS** pass — but our
    PREACCESS handler is pushed last and the phase engine flattens handlers in reverse push
    order, so our PREACCESS handler runs **before** realip's. A location-level `soft_limit_req`
    keyed on `$remote_addr` can therefore still read and cache the raw peer (same poisoning).
    (Test case `95` locks in this ordering **and** exercises the poisoning side effect: it
    asserts that even by the content phase `$remote_addr` reads the constant raw peer, because
    our POST_READ key eval cached it.)
- **Resolves, but to the *early* value (usually not what you want):** `$uri`. nginx sets
  `r->uri` while parsing the request line, *before* POST_READ, so a `$uri`-keyed server zone
  does resolve — but it keys on the **pre-rewrite, normalized** URI (the original request
  target), not the post-`rewrite`/post-internal-redirect URI you might expect. It does **not**
  silently bypass; it just keys on a value that ignores any later `rewrite`/`try_files`/
  `error_page` redirect. Use it only if keying on the original URI is genuinely intended.
- **NOT POST_READ-safe (genuinely empty — silent bypass):** `$upstream_*` (no upstream chosen
  until the content phase) and anything else set by a later phase. Keying a
  `soft_limit_req_server` zone on one of these makes the key empty at POST_READ, so the zone
  **silently bypasses** every request. Prefer `$host`/`$http_*`-keyed zones with this directive.

### Shared `set=$var` with `soft_limit_req` — last-writer-wins

The same `set=$var` name may be used by both directives (the verdict variable's get_handler
is backed by both the POST_READ and PREACCESS writers). If both write the **same** variable
on the same request, **PREACCESS wins** — `soft_limit_req_server` writes it in POST_READ and a
location-level `soft_limit_req` overwrites it later in PREACCESS (last-writer-wins =
PREACCESS). In practice the two directives target separate zones and separate verdict
variables, so this is an edge case, but it is worth stating: to read the *early* verdict in
the rewrite phase, give `soft_limit_req_server` its own `set=$var`.

Distinct from the verdict overwrite above: if both directives point at the **same zone**, that
zone's bucket is charged **twice** per request — once in POST_READ by `soft_limit_req_server`
and again in PREACCESS by `soft_limit_req`. Use **separate zones** for the two directives.

### Example — hard-reject in the rewrite phase via `if`

```nginx
soft_limit_req_zone $host zone=perhost:64m rate=12000r/s;

server {
    listen 80;
    server_name app.example;

    soft_limit_req_server zone=perhost burst=2000 set=$over_host;  # POST_READ

    location / {
        if ($over_host) { return 444; }   # rewrite phase — now sees the verdict
        proxy_pass http://main;
    }
}

upstream main { server backend.example:80; }
```

Once `$host` is over its cap, `$over_host` is `"1"` at POST_READ and the rewrite-phase `if`
fires (`444`). Under budget it is `""`, so the `if` is falsy and the request is proxied
normally.

### Example — content-phase `map` → `proxy_pass` still works

The original lazy routing pattern works unchanged with `soft_limit_req_server` (the verdict
is set early and survives into the content phase):

```nginx
soft_limit_req_zone $host zone=perhost:64m rate=12000r/s;

map $over_host $pool {            # http{} only; read lazily at proxy_pass
    "1"     grey_pool;
    default main;
}

server {
    listen 80;
    server_name app.example;

    soft_limit_req_server zone=perhost burst=2000 set=$over_host;  # POST_READ

    location / {
        proxy_pass http://$pool;   # main | grey_pool
    }
}

upstream main      { server backend.example:80; }
upstream grey_pool { server challenge.example:80; }   # sacrificial / challenge tier
```

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

- **Order vs stock `limit_req` in the same location: soft runs first (in the documented
  builds).** Both register PREACCESS-phase handlers, and the same nginx internals that pin the
  realip ordering above pin this one: this module is appended after the built-in `limit_req`
  (both `--add-dynamic-module` and static `--add-module` addons come after built-ins),
  postconfiguration runs in module order, and the phase engine flattens each phase's handlers
  in reverse push order — so this module's PREACCESS handler runs *before* stock `limit_req`.
  A request hard-rejected by stock (503) has therefore already charged the soft bucket —
  provided the soft lookup actually ran (non-empty key, main request, once-per-request budget
  not already consumed). Caveat: nginx does not document addon placement or the reverse
  flattening as a stable public contract, so treat this ordering — like the realip ordering
  above (locked in by case `95`) — as verified per pinned version, not guaranteed forever.

- **Over-budget accounting mirrors stock `limit_req`.** Once a bucket crosses `burst`, the
  request is tagged but stored excess / `last` are **not** advanced further (same as stock,
  which rejects at that point). Sustained accepted overload therefore does not accumulate
  unbounded "debt"; the bucket drains by wall-clock time from the last under-budget request, so
  a flooded host stays grey while letting a thin trickle through to `main`. This is the
  intended, stock-faithful behavior, not a leak.

- **Zone-full (`NGX_ERROR`) does not consume the once-per-request budget.** When a zone cannot
  allocate a node even after LRU eviction, nothing is charged, that directive's verdict stays
  `""`, and the once-per-request marker is left unset, so a limiter in a later
  internal-redirect target still accounts. This leg is a deliberate divergence from stock,
  which on `NGX_ERROR` sets `limit_req_status = REJECTED` (or `REJECTED_DRY_RUN`) and rejects
  the request.

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

### Install (Debian/Ubuntu package)

Tagged releases publish a `libnginx-mod-http-soft-limit-req_*.deb` per Ubuntu version, each
built against that distro's nginx.org mainline with an ABI-pinned `Depends` on the matching
`nginx`. Install with:

```sh
apt install ./libnginx-mod-http-soft-limit-req_<ver>_<arch>.deb
```

The package installs the `.so` to `/usr/lib/nginx/modules/` and a `load_module` snippet to
`/usr/share/nginx/modules-available/`, symlinked into `/etc/nginx/modules-enabled/`.

**Enabling — the package does NOT modify `nginx.conf`** (it never edits a file owned by the
`nginx` package):

- On a **Debian/Ubuntu distro `nginx`** (`nginx-common`), `nginx.conf` already sources
  `include /etc/nginx/modules-enabled/*.conf;` at the main context, so the module is enabled
  automatically — just `nginx -t && systemctl reload nginx`.
- On **nginx.org mainline `nginx`** (which ships no such include), add one main-context line
  to `nginx.conf` yourself (at the top level, outside `events{}` / `http{}`) — either source
  the directory or load the module directly:

```nginx
include /etc/nginx/modules-enabled/*.conf;
# — or, equivalently —
load_module modules/ngx_http_soft_limit_req_module.so;
```

## Testing

No C unit-test framework — the suite is Docker + curl/load (bash). It builds the `.so`
against pinned nginx, boots a container, and runs every `test/cases/*.sh`. Run:

```sh
./test/run.sh
```

Checks: 5 harness checks (`.so` built, `nginx -t` syntax + module load, server up,
`GET /` → 200) plus 18 behavior cases — zone + directive parsing (`10`, both
`soft_limit_req_zone` and the `soft_limit_req` location directive), never-rejects under flood
with the verdict actually flipping to `1` (`20`), single + multi `set=$var` (`30`/`31`), stock
IP hard-block coexisting with soft host routing via `map` plus the negative `if` phase-order
assertion (`40`), shm-stability soak (`50`), empty-key verified-bypass (`60`), zone-full /
alloc-failure graceful degradation (`70`), and the internal-redirect accounting cases —
same-zone re-entry counted once (`80`), redirect-target-only limiter accounts (`81`), and
bypass-entry-then-redirect-target (`82`). The `soft_limit_req_server` (POST_READ) directive
adds seven server-scope cases: `soft_limit_req_server` parse + scope acceptance, including
rejection inside `location{}` (`11`); the headline verdict-visible-in-REWRITE proof via
`if`→444 (`90`); single-charge across `try_files`/`error_page`/`rewrite ... last` re-entry
(`91`); coexistence of both directives on separate zones with independent budgets (`92`); the
key-readiness footgun encoded as an executable fact (an `$upstream_addr`-keyed zone whose
verdict never flips because the key is empty at POST_READ — `93`); http{}-level inheritance
firing at runtime on a server that declares none of its own (`94`); and the realip-vs-POST_READ
ordering ground truth — a `$remote_addr`-keyed server zone buckets on the raw TCP peer because
our handler runs before realip's POST_READ rewrite (`95`). The config snippets above
mirror `test/conf/nginx.conf`.

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
