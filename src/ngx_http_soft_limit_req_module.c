/*
 * Copyright (C) Igor Sysoev
 * Copyright (C) Nginx, Inc.
 *
 * ngx_http_soft_limit_req_module is a derivative work of nginx's
 * ngx_http_limit_req_module.c. The original nginx BSD-2-Clause copyright
 * (above) is retained as required. See LICENSE.
 */


#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_http.h>


typedef struct {
    u_char                            color;
    u_char                            dummy;
    u_short                           len;
    ngx_queue_t                       queue;
    ngx_msec_t                        last;
    /* integer value, 1 corresponds to 0.001 r/s */
    ngx_uint_t                        excess;
    u_char                            data[1];
} ngx_http_soft_limit_req_node_t;


typedef struct {
    ngx_rbtree_t                      rbtree;
    ngx_rbtree_node_t                 sentinel;
    ngx_queue_t                       queue;
} ngx_http_soft_limit_req_shctx_t;


typedef struct {
    ngx_http_soft_limit_req_shctx_t  *sh;
    ngx_slab_pool_t                  *shpool;
    /* integer value, 1 corresponds to 0.001 r/s */
    ngx_uint_t                        rate;
    ngx_http_complex_value_t          key;
} ngx_http_soft_limit_req_ctx_t;


typedef struct {
    ngx_shm_zone_t                   *shm_zone;
    /* integer value, 1 corresponds to 0.001 r/s */
    ngx_uint_t                        burst;
    /* target variable index for set=$var; NGX_CONF_UNSET if omitted */
    ngx_int_t                         set_index;
} ngx_http_soft_limit_req_limit_t;


typedef struct {
    ngx_array_t                       limits;
} ngx_http_soft_limit_req_conf_t;


/*
 * Server-scope configuration for the soft_limit_req_server directive.
 * Identical shape to the location conf (a single limits array, no flags):
 * the only difference is the conf scope (NGX_HTTP_SRV_CONF_OFFSET) and the
 * phase its handler runs in (POST_READ). Kept as a distinct type so the
 * create/merge slots and handler reads are unambiguous.
 */
typedef struct {
    ngx_array_t                       limits;
} ngx_http_soft_limit_req_srv_conf_t;


typedef struct {
    /*
     * Index into r->variables of an internal guard variable used as a
     * redirect-surviving "this request was already accounted" marker. See the
     * handler for why this replaces a request-struct bitfield.
     */
    ngx_int_t                         seen_index;
} ngx_http_soft_limit_req_main_conf_t;


/* internal guard variable name (never referenced by config; private storage) */
static ngx_str_t  ngx_http_soft_limit_req_seen_name =
    ngx_string("__soft_limit_req_seen");


static void ngx_http_soft_limit_req_rbtree_insert_value(
    ngx_rbtree_node_t *temp, ngx_rbtree_node_t *node,
    ngx_rbtree_node_t *sentinel);
static ngx_int_t ngx_http_soft_limit_req_lookup(
    ngx_http_soft_limit_req_limit_t *limit, ngx_uint_t hash, ngx_str_t *key,
    ngx_uint_t *ep);
static void ngx_http_soft_limit_req_expire(
    ngx_http_soft_limit_req_ctx_t *ctx, ngx_uint_t n);

static ngx_int_t ngx_http_soft_limit_req_handler(ngx_http_request_t *r);
static ngx_int_t ngx_http_soft_limit_req_server_handler(ngx_http_request_t *r);
static ngx_int_t ngx_http_soft_limit_req_run_limits(ngx_http_request_t *r,
    ngx_array_t *limits, ngx_http_variable_value_t *seen);
static ngx_int_t ngx_http_soft_limit_req_variable(ngx_http_request_t *r,
    ngx_http_variable_value_t *v, uintptr_t data);
static ngx_int_t ngx_http_soft_limit_req_init_zone(ngx_shm_zone_t *shm_zone,
    void *data);
static void *ngx_http_soft_limit_req_create_main_conf(ngx_conf_t *cf);
static void *ngx_http_soft_limit_req_create_srv_conf(ngx_conf_t *cf);
static char *ngx_http_soft_limit_req_merge_srv_conf(ngx_conf_t *cf,
    void *parent, void *child);
static void *ngx_http_soft_limit_req_create_conf(ngx_conf_t *cf);
static char *ngx_http_soft_limit_req_merge_conf(ngx_conf_t *cf, void *parent,
    void *child);
static char *ngx_http_soft_limit_req_zone(ngx_conf_t *cf, ngx_command_t *cmd,
    void *conf);
static char *ngx_http_soft_limit_req(ngx_conf_t *cf, ngx_command_t *cmd,
    void *conf);
static char *ngx_http_soft_limit_req_server(ngx_conf_t *cf, ngx_command_t *cmd,
    void *conf);
static char *ngx_http_soft_limit_req_parse(ngx_conf_t *cf, ngx_command_t *cmd,
    ngx_array_t *limits);
static ngx_int_t ngx_http_soft_limit_req_init(ngx_conf_t *cf);


static ngx_command_t  ngx_http_soft_limit_req_commands[] = {

    { ngx_string("soft_limit_req_zone"),
      NGX_HTTP_MAIN_CONF|NGX_CONF_TAKE3,
      ngx_http_soft_limit_req_zone,
      0,
      0,
      NULL },

    { ngx_string("soft_limit_req"),
      NGX_HTTP_SRV_CONF|NGX_HTTP_LOC_CONF|NGX_CONF_TAKE123,
      ngx_http_soft_limit_req,
      NGX_HTTP_LOC_CONF_OFFSET,
      0,
      NULL },

    /*
     * Server-scope, POST_READ. NGX_HTTP_MAIN_CONF is included (alongside
     * NGX_HTTP_SRV_CONF) so the directive is also accepted at http{} level: with
     * NGX_HTTP_SRV_CONF_OFFSET storage, an http-level instance lands in the
     * http-context srv conf, which merge_srv_conf propagates to ALL servers that
     * define none of their own — intended (documented in README). Deliberately
     * NOT NGX_HTTP_LOC_CONF: POST_READ runs before any location is matched.
     */
    { ngx_string("soft_limit_req_server"),
      NGX_HTTP_MAIN_CONF|NGX_HTTP_SRV_CONF|NGX_CONF_TAKE123,
      ngx_http_soft_limit_req_server,
      NGX_HTTP_SRV_CONF_OFFSET,
      0,
      NULL },

      ngx_null_command
};


static ngx_http_module_t  ngx_http_soft_limit_req_module_ctx = {
    NULL,                                  /* preconfiguration */
    ngx_http_soft_limit_req_init,          /* postconfiguration */

    ngx_http_soft_limit_req_create_main_conf, /* create main configuration */
    NULL,                                  /* init main configuration */

    ngx_http_soft_limit_req_create_srv_conf, /* create server configuration */
    ngx_http_soft_limit_req_merge_srv_conf,  /* merge server configuration */

    ngx_http_soft_limit_req_create_conf,   /* create location configuration */
    ngx_http_soft_limit_req_merge_conf     /* merge location configuration */
};


ngx_module_t  ngx_http_soft_limit_req_module = {
    NGX_MODULE_V1,
    &ngx_http_soft_limit_req_module_ctx,   /* module context */
    ngx_http_soft_limit_req_commands,      /* module directives */
    NGX_HTTP_MODULE,                       /* module type */
    NULL,                                  /* init master */
    NULL,                                  /* init module */
    NULL,                                  /* init process */
    NULL,                                  /* init thread */
    NULL,                                  /* exit thread */
    NULL,                                  /* exit process */
    NULL,                                  /* exit master */
    NGX_MODULE_V1_PADDING
};


static ngx_int_t
ngx_http_soft_limit_req_handler(ngx_http_request_t *r)
{
    ngx_http_variable_value_t            *seen;
    ngx_http_soft_limit_req_conf_t       *slrcf;
    ngx_http_soft_limit_req_main_conf_t  *slrmcf;

    /*
     * Account the leaky bucket EXACTLY ONCE per external request, on the FIRST
     * handler run that actually has limits to process — whether the soft-limited
     * location is reached directly OR only via an internal redirect. PREACCESS
     * re-runs after every internal redirect (try_files fallback to a URI/@named
     * target, error_page, X-Accel-Redirect), and runs for subrequests
     * (auth_request, mirror, SSI).
     *
     * Stock limit_req guards this with r->main->limit_req_status, a bitfield in
     * ngx_http_request_t. Critically, stock sets that field ONLY when the
     * handler actually processes a limit (it returns NGX_DECLINED without
     * setting it when the location has no limits — see ngx_http_limit_req_module
     * lines 262-263), so a limiter-free entry location does NOT consume the
     * once-per-request budget; the budget is consumed by the location that owns
     * the limiter, even when that location is the internal-redirect target. We
     * cannot add a field to ngx_http_request_t, so we replicate the SEMANTICS
     * with a redirect-surviving marker, and likewise only set it once we are
     * about to run real buckets:
     *
     *   - A self-marker via ngx_http_set_ctx() does NOT work: both
     *     ngx_http_internal_redirect() and ngx_http_named_location()
     *     ngx_memzero(r->ctx, ...) (ngx_http_core_module.c), wiping it on every
     *     internal redirect.
     *   - Gating on r->internal does NOT work either: it skips EVERY
     *     internal-redirect pass, so a soft-limited location reached ONLY via a
     *     redirect — the very common `location / { try_files $uri @app; }` +
     *     `location @app { proxy_pass ...; soft_limit_req ...; }` pattern — is
     *     never accounted and set=$var stays empty.
     *   - We instead use a one-shot marker in the variables array. Neither
     *     ngx_http_internal_redirect() nor ngx_http_named_location() touches
     *     r->variables, so a marker stored there SURVIVES the redirect. The
     *     slot is zeroed at request creation, so its `valid` flag reliably
     *     distinguishes the first accounting run from a re-entered one.
     *
     * The marker is consumed (seen->valid set) ONLY once a zone has actually
     * processed a key — i.e. reached the shmtx lock + lookup() with a non-empty,
     * non-oversized key. This mirrors stock's r->main->limit_req_status, which
     * is NOT set on the all-skip paths: stock initializes rc = NGX_DECLINED and,
     * if every key is empty (key.len == 0) or oversized (key.len > 65535) so the
     * loop only `continue`s, returns NGX_DECLINED at lines 262-263 WITHOUT ever
     * setting limit_req_status. Replicating that matters across internal
     * redirects: if an entry location's configured soft limits ALL bypass on
     * this request (e.g. keyed on an absent header -> empty key), the marker must
     * stay unset so a later redirect target that owns a REAL limiter still
     * accounts. Setting the marker too early (as soon as limits.nelts > 0, before
     * any bucket is touched) would burn the once-per-request budget on a pure
     * bypass and wrongly skip the redirect target.
     *
     * Subrequests are skipped via r != r->main. NOTE: this is NOT what stock
     * limit_req does — stock has no r != r->main check; it gates accounting on
     * r->main->limit_req_status, so a subrequest can still charge the bucket on
     * behalf of the main request. We deliberately diverge: for a tag-don't-
     * reject router, an auth_request / mirror / SSI subrequest must not
     * independently tag or account (it would write the verdict variable for an
     * internal helper request and skew the bucket), so we decline subrequests
     * outright and account only the main request. Note rewrite-last
     * (`rewrite ... last`) DOES set r->internal = 1 (any URI-changing rewrite
     * runs ngx_http_script_regex_start_code with code->uri set) but calls
     * neither redirect helper: post-rewrite rewinds the phase engine to
     * FIND_CONFIG, which is before PREACCESS, so there is still a single
     * PREACCESS pass and the request is accounted once, as it must be. (One
     * more reason an r->internal gate would be wrong: it would skip that
     * single pass too.)
     *
     * Because r == r->main below, r->variables IS r->main->variables. The first
     * accounting pass that does a real lookup sets seen->valid = 1 after running
     * the buckets; any later pass (after an internal redirect) sees valid == 1
     * and returns without re-accounting. The verdict written on that pass also
     * lives in r->variables and stays readable by the content-phase map on the
     * served (possibly redirected) request, so skipping the variable write on
     * later passes is correct. Setting the marker after the loop does not
     * short-circuit multi-zone evaluation: the entry guard (seen->valid) already
     * gated this whole pass, and every zone is evaluated within it.
     */

    if (r != r->main) {
        return NGX_DECLINED;
    }

    slrcf = ngx_http_get_module_loc_conf(r, ngx_http_soft_limit_req_module);

    if (slrcf->limits.nelts == 0) {
        /*
         * No limiter in this location — do nothing and, like stock, leave the
         * once-per-request budget untouched so a limited internal-redirect
         * target reached from here is still accounted.
         */
        return NGX_DECLINED;
    }

    slrmcf = ngx_http_get_module_main_conf(r, ngx_http_soft_limit_req_module);

    seen = &r->variables[slrmcf->seen_index];

    if (seen->valid) {
        /* already accounted this request (re-entered after a redirect) */
        return NGX_DECLINED;
    }

    /*
     * Run the shared accounting loop, passing the once-per-request marker so it
     * is consumed (seen->valid set) only if a zone actually charged a bucket.
     */
    return ngx_http_soft_limit_req_run_limits(r, &slrcf->limits, seen);
}


static ngx_int_t
ngx_http_soft_limit_req_server_handler(ngx_http_request_t *r)
{
    ngx_http_soft_limit_req_srv_conf_t  *slrscf;

    /*
     * Server-scope handler, registered in the POST_READ phase so its set=$var
     * verdict is written BEFORE the REWRITE phase and is therefore readable by
     * rewrite-phase consumers (if / rewrite / early log) as well as the
     * precontent-phase try_files (the verdict stays readable because PRECONTENT
     * runs after POST_READ), unlike the PREACCESS location-scope handler,
     * whose verdict is readable from the ACCESS phase onward (access,
     * precontent/try_files, content, log) but not by rewrite-phase consumers.
     *
     * NO ONCE-PER-REQUEST MARKER IS NEEDED HERE (unlike the PREACCESS handler).
     * The bucket is accounted EXACTLY ONCE per external request because POST_READ
     * runs exactly once on the external request and NEVER re-runs on any internal
     * re-entry. Verified against the pinned nginx source (nginx-1.31.1,
     * src/http/ngx_http_core_module.c):
     *
     *   - POST_READ is phase index 0 and SERVER_REWRITE is the next phase
     *     (ngx_http_core_module.h: NGX_HTTP_POST_READ_PHASE = 0, then
     *     NGX_HTTP_SERVER_REWRITE_PHASE). Anything that rewinds r->phase_handler
     *     to at/after server_rewrite_index re-enters AFTER POST_READ.
     *   - try_files fallback, error_page, and X-Accel-Redirect all funnel through
     *     ngx_http_internal_redirect() (line 2582), which calls ngx_http_handler()
     *     (line 2630) with r->internal == 1; ngx_http_handler() then sets
     *     r->phase_handler = cmcf->phase_engine.server_rewrite_index (line 868),
     *     i.e. PAST POST_READ.
     *   - ngx_http_named_location() (try_files -> @named, error_page -> @named;
     *     line 2637) sets r->phase_handler = cmcf->phase_engine.location_rewrite_index
     *     (line 2694) — later still, also past POST_READ.
     *   - `rewrite ... last` does NOT call either redirect helper: it loops within
     *     the phase engine via ngx_http_core_post_rewrite_phase() (line 1064),
     *     which sets r->phase_handler = ph->next (line 1099); for the
     *     POST_REWRITE checker ph->next is find_config_index — a rewind to
     *     FIND_CONFIG (re-runs location matching and the location rewrite
     *     phase), still strictly after POST_READ.
     *   - Subrequests (auth_request / mirror / SSI) are excluded by the
     *     r != r->main guard below: a helper request must neither tag nor account.
     *
     * Because no internal-redirect vector re-runs POST_READ and subrequests are
     * declined, a single un-marked accounting pass cannot double-charge. We pass
     * seen = NULL to ngx_http_soft_limit_req_run_limits() (no marker write). The
     * verdict written into r->variables survives the redirect (neither redirect
     * helper touches r->variables) and stays readable on the served request.
     */

    if (r != r->main) {
        return NGX_DECLINED;
    }

    slrscf = ngx_http_get_module_srv_conf(r, ngx_http_soft_limit_req_module);

    if (slrscf->limits.nelts == 0) {
        return NGX_DECLINED;
    }

    return ngx_http_soft_limit_req_run_limits(r, &slrscf->limits, NULL);
}


/*
 * Shared accounting core for both the PREACCESS (location-scope) and POST_READ
 * (server-scope) handlers. Tag-don't-reject: evaluate EVERY configured zone on
 * every request (no break on overflow), account in a single pass under the zone
 * shmtx, flip the per-directive set=$var verdict to "1" on overflow, and always
 * return NGX_DECLINED.
 *
 * `seen` is the optional once-per-request marker (a slot in r->variables):
 *   - PREACCESS passes its redirect-surviving guard slot; it is consumed
 *     (seen->valid set) after the loop ONLY if at least one zone actually
 *     charged a bucket (lookup() returned NGX_OK / NGX_BUSY). On an all-bypass
 *     pass (every key empty / oversized) it stays unset, mirroring stock's
 *     limit_req_status (stock lines 262-263). On an all-degraded pass (every
 *     zone full -> NGX_ERROR, nothing charged) it also stays unset — a
 *     DELIBERATE divergence from stock, which on NGX_ERROR sets
 *     limit_req_status = REJECTED (or REJECTED_DRY_RUN) and rejects; nothing
 *     was charged, so this never-reject fork keeps the once-per-request
 *     budget. Either way a later internal-redirect target still accounts.
 *   - POST_READ passes NULL: it runs exactly once per external request and
 *     needs no marker (see the POST_READ handler comment).
 *
 * The caller is responsible for the r != r->main and limits.nelts == 0 guards.
 */
static ngx_int_t
ngx_http_soft_limit_req_run_limits(ngx_http_request_t *r, ngx_array_t *limits,
    ngx_http_variable_value_t *seen)
{
    uint32_t                          hash;
    ngx_str_t                         key;
    ngx_int_t                         rc;
    ngx_uint_t                        n, excess, accounted;
    ngx_http_variable_value_t        *vv;
    ngx_http_soft_limit_req_ctx_t    *ctx;
    ngx_http_soft_limit_req_limit_t  *limit, *elts;

    /*
     * Track whether any zone actually CHARGED a bucket this pass (lookup()
     * returned NGX_OK or NGX_BUSY, not NGX_ERROR). The once-per-request marker
     * is consumed only if it did, so an all-bypass entry location (every key
     * empty / oversized) OR an all-degraded pass (every zone full) leaves the
     * budget for a redirect-target limiter.
     */
    accounted = 0;

    elts = limits->elts;

    for (n = 0; n < limits->nelts; n++) {

        limit = &elts[n];

        ctx = limit->shm_zone->data;

        /*
         * Initialize the per-directive set=$var to "" up front so that the
         * skipped paths (empty key / oversized key) and the under-budget path
         * all read as not-over. Only an actual overflow flips it to "1".
         */
        if (limit->set_index != NGX_CONF_UNSET) {
            vv = &r->variables[limit->set_index];
            vv->valid = 1;
            vv->not_found = 0;
            vv->no_cacheable = 0;
            vv->len = 0;
            vv->data = (u_char *) "";
        }

        if (ngx_http_complex_value(r, &ctx->key, &key) != NGX_OK) {
            /*
             * Soft limiter: NEVER fail the request. A key-evaluation failure
             * (e.g. allocation failure) is treated as a SKIP, exactly like the
             * empty-key / oversized-key paths below: the verdict variable stays
             * "" (initialized above), the zone is NOT accounted (we leave
             * `accounted` untouched), and we move on to the next zone. The
             * handler therefore always returns NGX_DECLINED and never charges a
             * partial set of zones it cannot finish.
             */
            ngx_log_error(NGX_LOG_ERR, r->connection->log, 0,
                          "soft_limit_req: failed to evaluate key, "
                          "skipping zone \"%V\"", &limit->shm_zone->shm.name);
            continue;
        }

        if (key.len == 0) {
            continue;
        }

        if (key.len > 65535) {
            ngx_log_error(NGX_LOG_ERR, r->connection->log, 0,
                          "the value of the \"%V\" key "
                          "is more than 65535 bytes: \"%V\"",
                          &ctx->key.value, &key);
            continue;
        }

        hash = ngx_crc32_short(key.data, key.len);

        excess = 0;

        ngx_shmtx_lock(&ctx->shpool->mutex);

        /* single-pass account: lr->excess / lr->last updated inline */
        rc = ngx_http_soft_limit_req_lookup(limit, hash, &key, &excess);

        ngx_shmtx_unlock(&ctx->shpool->mutex);

        /*
         * Consume the once-per-request marker only when lookup() actually
         * charged a bucket. NGX_OK (bucket updated / node created) and NGX_BUSY
         * (existing bucket over burst, LRU touched) both mean real accounting
         * happened. NGX_ERROR is the zone-full / slab-alloc-failure path: it
         * charges nothing, so we must NOT set `accounted` — leaving the budget
         * intact mirrors the empty-key / oversized-key skips, so a later
         * internal-redirect target with a real limiter still accounts. The
         * verdict variable stays "" on the NGX_ERROR path (graceful
         * degradation; never reject).
         */
        if (rc != NGX_ERROR) {
            accounted = 1;
        }

        ngx_log_debug4(NGX_LOG_DEBUG_HTTP, r->connection->log, 0,
                       "soft_limit_req[%ui]: %i %ui.%03ui",
                       n, rc, excess / 1000, excess % 1000);

        if (rc == NGX_BUSY) {
            /*
             * Log at INFO, NOT error. For a tag-don't-reject limiter, going
             * over budget is the NORMAL, expected hot path (it is exactly what
             * the module exists to detect and route), not an error condition.
             * This module is built for L7 floods, where over-budget requests
             * dominate; logging each one at NGX_LOG_ERR would turn expected
             * grey traffic into sustained error-log CPU/disk pressure and
             * misleading error telemetry — a self-inflicted amplifier on the
             * very path it is meant to handle. At INFO it stays silent under the
             * default error_log level and is available only when an operator
             * deliberately lowers the level to observe soft-limiting. (Stock
             * limit_req exposes limit_req_log_level for the same reason; a
             * dedicated soft_limit_req_log_level directive can be added later if
             * a configurable level is needed.)
             */
            ngx_log_error(NGX_LOG_INFO, r->connection->log, 0,
                          "soft limiting requests, "
                          "excess: %ui.%03ui by zone \"%V\"",
                          excess / 1000, excess % 1000,
                          &limit->shm_zone->shm.name);

            /* overflow (excess > burst): flip the verdict variable to "1" */
            if (limit->set_index != NGX_CONF_UNSET) {
                vv = &r->variables[limit->set_index];
                vv->valid = 1;
                vv->not_found = 0;
                vv->no_cacheable = 0;
                vv->len = 1;
                vv->data = (u_char *) "1";
            }
        }

        /* never break: continue to the next zone regardless of verdict */
    }

    /*
     * Consume the once-per-request marker only if at least one zone actually
     * charged a bucket (lookup() returned NGX_OK / NGX_BUSY). On an all-bypass
     * pass (every key empty or oversized) the marker stays unset, mirroring
     * stock's limit_req_status; on an all-degraded pass (every zone full ->
     * NGX_ERROR, nothing charged) it stays unset as a deliberate divergence
     * from stock (which sets limit_req_status and rejects on NGX_ERROR).
     * Either way a later internal-redirect target with a real limiter still
     * accounts. A NULL seen (POST_READ) skips the marker entirely.
     */
    if (seen != NULL && accounted) {
        seen->valid = 1;
        seen->not_found = 0;
    }

    return NGX_DECLINED;
}


static ngx_int_t
ngx_http_soft_limit_req_variable(ngx_http_request_t *r,
    ngx_http_variable_value_t *v, uintptr_t data)
{
    /*
     * Default get_handler for a set=$var that neither the PREACCESS nor the
     * POST_READ handler wrote on this request (e.g. the location/server has no
     * soft_limit_req(_server), or the variable is read before either handler
     * runs). Report not-found so it reads as empty/false rather than leaking a
     * stale value.
     */
    v->not_found = 1;

    return NGX_OK;
}


static void
ngx_http_soft_limit_req_rbtree_insert_value(ngx_rbtree_node_t *temp,
    ngx_rbtree_node_t *node, ngx_rbtree_node_t *sentinel)
{
    ngx_rbtree_node_t               **p;
    ngx_http_soft_limit_req_node_t   *lrn, *lrnt;

    for ( ;; ) {

        if (node->key < temp->key) {

            p = &temp->left;

        } else if (node->key > temp->key) {

            p = &temp->right;

        } else { /* node->key == temp->key */

            lrn = (ngx_http_soft_limit_req_node_t *) &node->color;
            lrnt = (ngx_http_soft_limit_req_node_t *) &temp->color;

            p = (ngx_memn2cmp(lrn->data, lrnt->data, lrn->len, lrnt->len) < 0)
                ? &temp->left : &temp->right;
        }

        if (*p == sentinel) {
            break;
        }

        temp = *p;
    }

    *p = node;
    node->parent = temp;
    node->left = sentinel;
    node->right = sentinel;
    ngx_rbt_red(node);
}


static ngx_int_t
ngx_http_soft_limit_req_lookup(ngx_http_soft_limit_req_limit_t *limit,
    ngx_uint_t hash, ngx_str_t *key, ngx_uint_t *ep)
{
    size_t                           size;
    ngx_int_t                        rc, excess;
    ngx_msec_t                       now;
    ngx_msec_int_t                   ms;
    ngx_rbtree_node_t               *node, *sentinel;
    ngx_http_soft_limit_req_ctx_t   *ctx;
    ngx_http_soft_limit_req_node_t  *lr;

    now = ngx_current_msec;

    ctx = limit->shm_zone->data;

    node = ctx->sh->rbtree.root;
    sentinel = ctx->sh->rbtree.sentinel;

    while (node != sentinel) {

        if (hash < node->key) {
            node = node->left;
            continue;
        }

        if (hash > node->key) {
            node = node->right;
            continue;
        }

        /* hash == node->key */

        lr = (ngx_http_soft_limit_req_node_t *) &node->color;

        rc = ngx_memn2cmp(key->data, lr->data, key->len, (size_t) lr->len);

        if (rc == 0) {
            ngx_queue_remove(&lr->queue);
            ngx_queue_insert_head(&ctx->sh->queue, &lr->queue);

            ms = (ngx_msec_int_t) (now - lr->last);

            if (ms < -60000) {
                ms = 1;

            } else if (ms < 0) {
                ms = 0;
            }

            excess = lr->excess - ctx->rate * ms / 1000 + 1000;

            if (excess < 0) {
                excess = 0;
            }

            *ep = excess;

            if ((ngx_uint_t) excess > limit->burst) {
                return NGX_BUSY;
            }

            /*
             * Single-pass account: the sole caller always accounts, so there
             * is no two-phase reservation. Update the bucket inline and return.
             */
            lr->excess = excess;

            if (ms) {
                lr->last = now;
            }

            return NGX_OK;
        }

        node = (rc < 0) ? node->left : node->right;
    }

    *ep = 0;

    size = offsetof(ngx_rbtree_node_t, color)
           + offsetof(ngx_http_soft_limit_req_node_t, data)
           + key->len;

    ngx_http_soft_limit_req_expire(ctx, 1);

    node = ngx_slab_alloc_locked(ctx->shpool, size);

    if (node == NULL) {
        ngx_http_soft_limit_req_expire(ctx, 0);

        node = ngx_slab_alloc_locked(ctx->shpool, size);
        if (node == NULL) {
            ngx_log_error(NGX_LOG_ALERT, ngx_cycle->log, 0,
                          "could not allocate node%s", ctx->shpool->log_ctx);
            return NGX_ERROR;
        }
    }

    node->key = hash;

    lr = (ngx_http_soft_limit_req_node_t *) &node->color;

    lr->len = (u_short) key->len;
    lr->excess = 0;

    ngx_memcpy(lr->data, key->data, key->len);

    ngx_rbtree_insert(&ctx->sh->rbtree, node);

    ngx_queue_insert_head(&ctx->sh->queue, &lr->queue);

    lr->last = now;

    return NGX_OK;
}


static void
ngx_http_soft_limit_req_expire(ngx_http_soft_limit_req_ctx_t *ctx,
    ngx_uint_t n)
{
    ngx_int_t                        excess;
    ngx_msec_t                       now;
    ngx_queue_t                     *q;
    ngx_msec_int_t                   ms;
    ngx_rbtree_node_t               *node;
    ngx_http_soft_limit_req_node_t  *lr;

    now = ngx_current_msec;

    /*
     * n == 1 deletes one or two zero rate entries
     * n == 0 deletes oldest entry by force
     *        and one or two zero rate entries
     */

    while (n < 3) {

        if (ngx_queue_empty(&ctx->sh->queue)) {
            return;
        }

        q = ngx_queue_last(&ctx->sh->queue);

        lr = ngx_queue_data(q, ngx_http_soft_limit_req_node_t, queue);

        /*
         * No node is ever pinned: the single-pass account never holds a node
         * reference past the shmtx unlock, so there is no count>0 guard here
         * (stock keeps one for its two-phase reservation, which this fork
         * dropped). The LRU tail is always evictable.
         */

        if (n++ != 0) {

            ms = (ngx_msec_int_t) (now - lr->last);
            ms = ngx_abs(ms);

            if (ms < 60000) {
                return;
            }

            excess = lr->excess - ctx->rate * ms / 1000;

            if (excess > 0) {
                return;
            }
        }

        ngx_queue_remove(q);

        node = (ngx_rbtree_node_t *)
                   ((u_char *) lr - offsetof(ngx_rbtree_node_t, color));

        ngx_rbtree_delete(&ctx->sh->rbtree, node);

        ngx_slab_free_locked(ctx->shpool, node);
    }
}


static ngx_int_t
ngx_http_soft_limit_req_init_zone(ngx_shm_zone_t *shm_zone, void *data)
{
    ngx_http_soft_limit_req_ctx_t  *octx = data;

    size_t                          len;
    ngx_http_soft_limit_req_ctx_t  *ctx;

    ctx = shm_zone->data;

    if (octx) {
        if (ctx->key.value.len != octx->key.value.len
            || ngx_strncmp(ctx->key.value.data, octx->key.value.data,
                           ctx->key.value.len)
               != 0)
        {
            ngx_log_error(NGX_LOG_EMERG, shm_zone->shm.log, 0,
                          "soft_limit_req \"%V\" uses the \"%V\" key "
                          "while previously it used the \"%V\" key",
                          &shm_zone->shm.name, &ctx->key.value,
                          &octx->key.value);
            return NGX_ERROR;
        }

        ctx->sh = octx->sh;
        ctx->shpool = octx->shpool;

        return NGX_OK;
    }

    ctx->shpool = (ngx_slab_pool_t *) shm_zone->shm.addr;

    if (shm_zone->shm.exists) {
        ctx->sh = ctx->shpool->data;

        return NGX_OK;
    }

    ctx->sh = ngx_slab_alloc(ctx->shpool,
                             sizeof(ngx_http_soft_limit_req_shctx_t));
    if (ctx->sh == NULL) {
        return NGX_ERROR;
    }

    ctx->shpool->data = ctx->sh;

    ngx_rbtree_init(&ctx->sh->rbtree, &ctx->sh->sentinel,
                    ngx_http_soft_limit_req_rbtree_insert_value);

    ngx_queue_init(&ctx->sh->queue);

    len = sizeof(" in soft_limit_req zone \"\"") + shm_zone->shm.name.len;

    ctx->shpool->log_ctx = ngx_slab_alloc(ctx->shpool, len);
    if (ctx->shpool->log_ctx == NULL) {
        return NGX_ERROR;
    }

    ngx_sprintf(ctx->shpool->log_ctx, " in soft_limit_req zone \"%V\"%Z",
                &shm_zone->shm.name);

    ctx->shpool->log_nomem = 0;

    return NGX_OK;
}


static char *
ngx_http_soft_limit_req_zone(ngx_conf_t *cf, ngx_command_t *cmd, void *conf)
{
    u_char                            *p;
    size_t                             len;
    ssize_t                            size;
    ngx_str_t                         *value, name, s;
    ngx_int_t                          rate, scale;
    ngx_uint_t                         i;
    ngx_shm_zone_t                    *shm_zone;
    ngx_http_soft_limit_req_ctx_t     *ctx;
    ngx_http_compile_complex_value_t   ccv;

    value = cf->args->elts;

    ctx = ngx_pcalloc(cf->pool, sizeof(ngx_http_soft_limit_req_ctx_t));
    if (ctx == NULL) {
        return NGX_CONF_ERROR;
    }

    ngx_memzero(&ccv, sizeof(ngx_http_compile_complex_value_t));

    ccv.cf = cf;
    ccv.value = &value[1];
    ccv.complex_value = &ctx->key;

    if (ngx_http_compile_complex_value(&ccv) != NGX_OK) {
        return NGX_CONF_ERROR;
    }

    size = 0;
    rate = 1;
    scale = 1;
    name.len = 0;

    for (i = 2; i < cf->args->nelts; i++) {

        if (ngx_strncmp(value[i].data, "zone=", 5) == 0) {

            name.data = value[i].data + 5;

            p = (u_char *) ngx_strchr(name.data, ':');

            if (p == NULL) {
                ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                                   "invalid zone size \"%V\"", &value[i]);
                return NGX_CONF_ERROR;
            }

            name.len = p - name.data;

            s.data = p + 1;
            s.len = value[i].data + value[i].len - s.data;

            size = ngx_parse_size(&s);

            if (size == NGX_ERROR) {
                ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                                   "invalid zone size \"%V\"", &value[i]);
                return NGX_CONF_ERROR;
            }

            if (size < (ssize_t) (8 * ngx_pagesize)) {
                ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                                   "zone \"%V\" is too small", &value[i]);
                return NGX_CONF_ERROR;
            }

            continue;
        }

        if (ngx_strncmp(value[i].data, "rate=", 5) == 0) {

            len = value[i].len;
            p = value[i].data + len - 3;

            if (ngx_strncmp(p, "r/s", 3) == 0) {
                scale = 1;
                len -= 3;

            } else if (ngx_strncmp(p, "r/m", 3) == 0) {
                scale = 60;
                len -= 3;
            }

            rate = ngx_atoi(value[i].data + 5, len - 5);
            if (rate <= 0) {
                ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                                   "invalid rate \"%V\"", &value[i]);
                return NGX_CONF_ERROR;
            }

            continue;
        }

        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                           "invalid parameter \"%V\"", &value[i]);
        return NGX_CONF_ERROR;
    }

    if (name.len == 0) {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                           "\"%V\" must have \"zone\" parameter",
                           &cmd->name);
        return NGX_CONF_ERROR;
    }

    ctx->rate = rate * 1000 / scale;

    shm_zone = ngx_shared_memory_add(cf, &name, size,
                                     &ngx_http_soft_limit_req_module);
    if (shm_zone == NULL) {
        return NGX_CONF_ERROR;
    }

    if (shm_zone->data) {
        ctx = shm_zone->data;

        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                           "%V \"%V\" is already bound to key \"%V\"",
                           &cmd->name, &name, &ctx->key.value);
        return NGX_CONF_ERROR;
    }

    shm_zone->init = ngx_http_soft_limit_req_init_zone;
    shm_zone->data = ctx;

    return NGX_CONF_OK;
}


/*
 * Thin wrapper for the location/server-inherited soft_limit_req directive
 * (PREACCESS). Resolves its own (location) conf and hands the target limits
 * array to the shared parser below. soft_limit_req_server has its own wrapper
 * resolving the srv conf; both share ngx_http_soft_limit_req_parse so duplicate-
 * zone detection and array-init are relative to whichever conf the directive
 * writes to.
 */
static char *
ngx_http_soft_limit_req(ngx_conf_t *cf, ngx_command_t *cmd, void *conf)
{
    ngx_http_soft_limit_req_conf_t  *slrcf = conf;

    return ngx_http_soft_limit_req_parse(cf, cmd, &slrcf->limits);
}


/*
 * Thin wrapper for the server-scope soft_limit_req_server directive (POST_READ).
 * Resolves its srv conf and hands its limits array to the shared parser.
 */
static char *
ngx_http_soft_limit_req_server(ngx_conf_t *cf, ngx_command_t *cmd, void *conf)
{
    ngx_http_soft_limit_req_srv_conf_t  *slrscf = conf;

    return ngx_http_soft_limit_req_parse(cf, cmd, &slrscf->limits);
}


/*
 * Shared parser for both soft_limit_req (location/server) and
 * soft_limit_req_server. `limits` is the TARGET array of the resolving
 * directive's conf: array-init and duplicate-zone detection are performed
 * against it so each directive writes only to its own scope. The pool used for
 * the array is cf->pool, matching the conf the wrapper resolved.
 */
static char *
ngx_http_soft_limit_req_parse(ngx_conf_t *cf, ngx_command_t *cmd,
    ngx_array_t *limits)
{
    ngx_int_t                         burst, set_index;
    ngx_str_t                        *value, s, name;
    ngx_uint_t                        i;
    ngx_shm_zone_t                   *shm_zone;
    ngx_http_variable_t              *var;
    ngx_http_soft_limit_req_limit_t  *limit, *elts;

    value = cf->args->elts;

    shm_zone = NULL;
    burst = 0;
    set_index = NGX_CONF_UNSET;

    for (i = 1; i < cf->args->nelts; i++) {

        if (ngx_strncmp(value[i].data, "zone=", 5) == 0) {

            s.len = value[i].len - 5;
            s.data = value[i].data + 5;

            shm_zone = ngx_shared_memory_add(cf, &s, 0,
                                             &ngx_http_soft_limit_req_module);
            if (shm_zone == NULL) {
                return NGX_CONF_ERROR;
            }

            continue;
        }

        if (ngx_strncmp(value[i].data, "burst=", 6) == 0) {

            burst = ngx_atoi(value[i].data + 6, value[i].len - 6);
            if (burst <= 0) {
                ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                                   "invalid burst value \"%V\"", &value[i]);
                return NGX_CONF_ERROR;
            }

            continue;
        }

        if (ngx_strncmp(value[i].data, "set=", 4) == 0) {

            name.len = value[i].len - 4;
            name.data = value[i].data + 4;

            if (name.len < 2 || name.data[0] != '$') {
                ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                                   "invalid variable name \"%V\"", &value[i]);
                return NGX_CONF_ERROR;
            }

            /* strip the leading '$' */
            name.len--;
            name.data++;

            /*
             * Reject the internal guard variable name. set=$var resolves into
             * the same variable namespace as the guard registration, so aliasing
             * it would let the per-directive verdict init flip the
             * once-per-request marker early and corrupt accounting across
             * internal redirects. The comparison is case-INSENSITIVE because
             * nginx/Angie variable names are case-insensitive (add_variable /
             * get_variable_index lowercase before comparing), so a mixed-case
             * variant would alias the same guard slot. Single source of truth:
             * ngx_http_soft_limit_req_seen_name (also used at registration).
             */
            if (name.len == ngx_http_soft_limit_req_seen_name.len
                && ngx_strncasecmp(name.data,
                                   ngx_http_soft_limit_req_seen_name.data,
                                   name.len)
                   == 0)
            {
                ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                                   "\"set=$%V\" uses a name reserved by "
                                   "soft_limit_req",
                                   &ngx_http_soft_limit_req_seen_name);
                return NGX_CONF_ERROR;
            }

            var = ngx_http_add_variable(cf, &name, NGX_HTTP_VAR_CHANGEABLE);
            if (var == NULL) {
                return NGX_CONF_ERROR;
            }

            /*
             * The PREACCESS or POST_READ handler writes r->variables[set_index]
             * directly; the get_handler only fires when neither handler ran for
             * this request, in which case the variable reads as not-found
             * (empty). If the SAME set=$var is shared by both soft_limit_req and
             * soft_limit_req_server, ngx_http_add_variable returns the existing
             * variable, so this get_handler == NULL check is skipped on the
             * second registration (harmless). Both handlers back the same slot;
             * last-writer-wins = PREACCESS (it runs after POST_READ on the same
             * request, overwriting any POST_READ verdict). In practice the two
             * directives target separate zones and separate verdict variables.
             */
            if (var->get_handler == NULL) {
                var->get_handler = ngx_http_soft_limit_req_variable;
            }

            set_index = ngx_http_get_variable_index(cf, &name);
            if (set_index == NGX_ERROR) {
                return NGX_CONF_ERROR;
            }

            continue;
        }

        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                           "invalid parameter \"%V\"", &value[i]);
        return NGX_CONF_ERROR;
    }

    if (shm_zone == NULL) {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                           "\"%V\" must have \"zone\" parameter",
                           &cmd->name);
        return NGX_CONF_ERROR;
    }

    elts = limits->elts;

    if (elts == NULL) {
        if (ngx_array_init(limits, cf->pool, 1,
                           sizeof(ngx_http_soft_limit_req_limit_t))
            != NGX_OK)
        {
            return NGX_CONF_ERROR;
        }
    }

    for (i = 0; i < limits->nelts; i++) {
        if (shm_zone == elts[i].shm_zone) {
            return "is duplicate";
        }
    }

    limit = ngx_array_push(limits);
    if (limit == NULL) {
        return NGX_CONF_ERROR;
    }

    limit->shm_zone = shm_zone;
    limit->burst = burst * 1000;
    limit->set_index = set_index;

    return NGX_CONF_OK;
}


static void *
ngx_http_soft_limit_req_create_main_conf(ngx_conf_t *cf)
{
    ngx_http_soft_limit_req_main_conf_t  *conf;

    conf = ngx_pcalloc(cf->pool,
                       sizeof(ngx_http_soft_limit_req_main_conf_t));
    if (conf == NULL) {
        return NULL;
    }

    conf->seen_index = NGX_CONF_UNSET;

    return conf;
}


static void *
ngx_http_soft_limit_req_create_srv_conf(ngx_conf_t *cf)
{
    ngx_http_soft_limit_req_srv_conf_t  *conf;

    conf = ngx_pcalloc(cf->pool,
                       sizeof(ngx_http_soft_limit_req_srv_conf_t));
    if (conf == NULL) {
        return NULL;
    }

    /*
     * set by ngx_pcalloc():
     *
     *     conf->limits.elts = NULL;
     */

    return conf;
}


static char *
ngx_http_soft_limit_req_merge_srv_conf(ngx_conf_t *cf, void *parent,
    void *child)
{
    ngx_http_soft_limit_req_srv_conf_t  *prev = parent;
    ngx_http_soft_limit_req_srv_conf_t  *conf = child;

    /*
     * http -> server inheritance (same elts == NULL idiom as the loc merge):
     * a server that defines no soft_limit_req_server of its own inherits the
     * http-level limits. Consequently an http{}-level soft_limit_req_server is
     * inherited by ALL servers — this is intended (documented in README).
     */
    if (conf->limits.elts == NULL) {
        conf->limits = prev->limits;
    }

    return NGX_CONF_OK;
}


static void *
ngx_http_soft_limit_req_create_conf(ngx_conf_t *cf)
{
    ngx_http_soft_limit_req_conf_t  *conf;

    conf = ngx_pcalloc(cf->pool, sizeof(ngx_http_soft_limit_req_conf_t));
    if (conf == NULL) {
        return NULL;
    }

    /*
     * set by ngx_pcalloc():
     *
     *     conf->limits.elts = NULL;
     */

    return conf;
}


static char *
ngx_http_soft_limit_req_merge_conf(ngx_conf_t *cf, void *parent, void *child)
{
    ngx_http_soft_limit_req_conf_t  *prev = parent;
    ngx_http_soft_limit_req_conf_t  *conf = child;

    if (conf->limits.elts == NULL) {
        conf->limits = prev->limits;
    }

    return NGX_CONF_OK;
}


static ngx_int_t
ngx_http_soft_limit_req_init(ngx_conf_t *cf)
{
    ngx_http_handler_pt                  *h;
    ngx_http_variable_t                  *var;
    ngx_http_core_main_conf_t            *cmcf;
    ngx_http_soft_limit_req_main_conf_t  *slrmcf;

    /*
     * Register an internal guard variable to obtain a stable per-request slot
     * in r->variables, used by the handler as a redirect-surviving "already
     * accounted this request" marker (see the handler comment). It is never
     * referenced by config — the slot is private storage, not read through the
     * variable machinery — so NGX_HTTP_VAR_NOHASH keeps it out of the runtime
     * lookup hash. It still needs a get_handler: an INDEXED variable with a
     * NULL get_handler fails ngx_http_variables_init_vars() with "unknown
     * variable", so we point it at the same not-found handler the set=$var
     * variables use (it never actually fires for the guard, since the handler
     * sets the slot's `valid` flag directly).
     *
     * RESERVED NAME: "__soft_limit_req_seen" is reserved for this internal
     * marker and must not collide with any config-defined variable. The set=
     * parser enforces this for set=$var (case-insensitive reject), but nginx
     * has a single shared variable namespace: any OTHER variable-producing
     * directive (set, map, geo, *_set, etc.) that predeclares this exact name
     * would alias the guard slot and corrupt once-per-request accounting. This
     * is documented as a reserved name in README; a fully robust fix would
     * require poking nginx's internal variable tables (version-fragile, against
     * this module's ride-the-stable-ABI design), so it is an accepted
     * limitation — do not define or use this name in configuration.
     */
    var = ngx_http_add_variable(cf, &ngx_http_soft_limit_req_seen_name,
                                NGX_HTTP_VAR_CHANGEABLE
                                | NGX_HTTP_VAR_NOCACHEABLE
                                | NGX_HTTP_VAR_NOHASH);
    if (var == NULL) {
        return NGX_ERROR;
    }

    var->get_handler = ngx_http_soft_limit_req_variable;

    slrmcf = ngx_http_conf_get_module_main_conf(cf,
                                            ngx_http_soft_limit_req_module);

    slrmcf->seen_index =
        ngx_http_get_variable_index(cf, &ngx_http_soft_limit_req_seen_name);
    if (slrmcf->seen_index == NGX_ERROR) {
        return NGX_ERROR;
    }

    cmcf = ngx_http_conf_get_module_main_conf(cf, ngx_http_core_module);

    h = ngx_array_push(&cmcf->phases[NGX_HTTP_PREACCESS_PHASE].handlers);
    if (h == NULL) {
        return NGX_ERROR;
    }

    *h = ngx_http_soft_limit_req_handler;

    /*
     * Server-scope handler in POST_READ: runs once per external request, before
     * the REWRITE phase, so its verdict variable is visible to rewrite-phase
     * directives. No once-per-request marker needed (see the handler comment for
     * the verified-against-nginx-source no-double-charge invariant).
     *
     * Ordering vs ngx_http_realip_module (verified against nginx 1.31.1): realip
     * also registers a POST_READ handler (ngx_http_realip_module.c). nginx calls
     * postconfiguration in module order (ngx_http.c ngx_http_block), and an
     * --add-dynamic-module module is appended LAST in the module array
     * (ngx_module.c ngx_add_module: before = modules_n when no explicit order),
     * so our postconfiguration runs AFTER realip's and we push our POST_READ
     * handler AFTER realip's. ngx_http_init_phase_handlers() then flattens each
     * phase's handlers in REVERSE push order (for j = nelts-1; j >= 0; j--), so
     * the LAST-pushed handler runs FIRST. Net effect: THIS handler runs BEFORE
     * realip rewrites $remote_addr. A $remote_addr-keyed server zone therefore
     * sees the raw TCP peer, not the realip client IP (documented in README +
     * proven by test case 95). Keep this in mind if the registration order or
     * build mode ever changes.
     */
    h = ngx_array_push(&cmcf->phases[NGX_HTTP_POST_READ_PHASE].handlers);
    if (h == NULL) {
        return NGX_ERROR;
    }

    *h = ngx_http_soft_limit_req_server_handler;

    return NGX_OK;
}
