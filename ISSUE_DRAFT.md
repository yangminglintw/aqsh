# feat: add `allowed_users` for per-ServiceAccount authorization

## Problem

`allowed_groups` does exact-match on `X-Forwarded-Groups`, which works at the namespace level but cannot authorize a specific Kubernetes ServiceAccount.

When fronted by [`kube-auth-proxy`](https://github.com/rophy/kube-auth-proxy) (which forwards Kubernetes TokenReview results), a real ServiceAccount token produces these headers:

```
X-Forwarded-User:   system:serviceaccount:my-ns:my-sa
X-Forwarded-Groups: system:serviceaccounts,
                    system:serviceaccounts:my-ns,
                    system:authenticated
```

Kubernetes TokenReview **never** includes the full SA `system:serviceaccount:<ns>:<name>` as a group — that string only appears as the username. See the upstream Kubernetes documentation: [Service account tokens — Authentication](https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/#bound-service-account-tokens) and [Service account roles and groups](https://kubernetes.io/docs/reference/access-authn-authz/rbac/#service-account-permissions).

Because aqsh's authorization (`internal/api/api.go` `hasAnyGroup`) is pure string equality and `X-Forwarded-User` is read but never compared against any allowlist (only logged / stored for audit), there is currently no way to write a task that allows only `my-sa` in `my-ns`.

## Environment

- aqsh: `rophy/aqsh@1eded18` (current `main` HEAD at the time of writing)
- Go: 1.24 (per `Dockerfile`)
- Docker Desktop on macOS (Darwin 25.1)
- Test runner: `docker compose up` with `redis:7-alpine` + locally-built aqsh image

## Reproduction

`tasks.yaml`:

```yaml
tasks:
  ns-only:
    script: hello.sh
    allowed_groups: ["system:serviceaccounts:rdsma"]
  sa-only:
    script: hello.sh
    allowed_groups: ["system:serviceaccount:rdsma:sertdxkkk"]
```

Test matrix (all calls send `X-Forwarded-User: system:serviceaccount:rdsma:sertdxkkk`):

| # | Task | `X-Forwarded-Groups` (what kube-auth-proxy actually sends) | Result |
|---|---|---|---|
| A | `ns-only` | `system:serviceaccounts,system:serviceaccounts:rdsma,system:authenticated` | **202** ✅ baseline matcher works |
| B | `ns-only` | `system:serviceaccounts,system:authenticated` (no `rdsma`) | **403** ✅ correctly denied |
| C | `sa-only` | `system:serviceaccounts,system:serviceaccounts:rdsma,system:authenticated` | **403** ❌ no realistic header value can grant this |

A and B confirm `allowed_groups` matching is correct. C is the gap: **there exists no value of `X-Forwarded-Groups` that any TokenReview-based proxy would produce that allows `sa-only` to succeed**, because Kubernetes does not synthesize a per-SA group.

Reproducible curl (against a local `docker compose` instance with the tasks.yaml above):

```bash
curl -sS -o /dev/stderr -w "HTTP %{http_code}\n" \
  -X POST http://localhost:8080/tasks/sa-only \
  -H "X-Forwarded-User: system:serviceaccount:rdsma:sertdxkkk" \
  -H "X-Forwarded-Groups: system:serviceaccounts,system:serviceaccounts:rdsma,system:authenticated" \
  -d '{}'
# => HTTP 403  {"error":"not authorized for this task"}
```

## Use case

Multi-tenant cluster where multiple ServiceAccounts share a namespace, but only one specific SA should be allowed to run a sensitive task (e.g., production deploy). Namespace-level authorization is too coarse — every SA in `platform` can run prod deploys today, not just `platform/deployer`.

## Proposal

Add a complementary `allowed_users` field to `TaskDef`, matched against the identity header (`X-Forwarded-User`, configurable via `AQSH_IDENTITY_HEADER`):

```yaml
tasks:
  prod-deploy:
    script: deploy.sh
    allowed_users:
      - "system:serviceaccount:platform:deployer"
    allowed_groups:
      - "system:serviceaccounts:platform-admin"
```

### Semantics: OR-combined

A request passes if it matches **any** entry in either list. This mirrors Kubernetes RBAC `RoleBinding.subjects` semantics, where any matching subject (user, group, or service account) grants access — adding an `allowed_users` entry should be additive, not narrow what `allowed_groups` already permits. When `allowed_users` is empty, behavior is identical to today, so the change is fully backward-compatible.

### Optional follow-up: federation awareness

When [`kube-federated-auth`](https://github.com/rophy/kube-federated-auth) is used, kube-auth-proxy adds `X-Forwarded-Extra-Cluster-Name`. Same-named SAs across clusters currently collide (cluster-A's `platform/deployer` and cluster-B's `platform/deployer` are indistinguishable to aqsh). A future enhancement could match on `(cluster, user)` for cross-cluster setups — likely a separate issue.

## Sketch of changes (starting point for discussion — happy to defer to your preferred design)

- `internal/tasks/tasks.go` (`TaskDef`): add `AllowedUsers []string` with `yaml:"allowed_users"`
- `internal/api/api.go` (around the existing `hasAnyGroup` check): add a parallel identity check, OR-combined with the groups check
- `internal/api/api_test.go`: cases for users-only, groups-only, both (OR), neither (open)
- `README.md` / `docs/api.md`: document `allowed_users` in the authorization section

I'm willing to open a PR if this approach is acceptable; otherwise, I'm happy to align with whatever shape you'd prefer.
