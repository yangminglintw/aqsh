# [DRAFT] feat: support per-identity (user/serviceaccount) authorization, not only groups

## Problem

`allowed_groups` does exact-match on `X-Forwarded-Groups`, which works at the namespace level but cannot authorize a specific Kubernetes ServiceAccount.

When fronted by [`kube-auth-proxy`](https://github.com/rophy/kube-auth-proxy) (which forwards Kubernetes TokenReview results), a real ServiceAccount token produces these headers:

```
X-Forwarded-User:   system:serviceaccount:my-ns:my-sa
X-Forwarded-Groups: system:serviceaccounts,
                    system:serviceaccounts:my-ns,
                    system:authenticated
```

Kubernetes TokenReview **never** includes the full SA `system:serviceaccount:<ns>:<name>` as a group — that string only appears as the username. Because aqsh's authorization (`internal/api/api.go` `hasAnyGroup`) is pure string equality and `X-Forwarded-User` is read but never compared against any allowlist (only logged / stored for audit), there is currently no way to write a task that allows only `my-sa` in `my-ns`.

## Reproduction (rophy/aqsh main, commit `1eded18`)

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

A and B confirm `allowed_groups` matching is correct. C is the gap: **there exists no value of `X-Forwarded-Groups` that any TokenReview-based proxy would produce that allows `sa-only` to succeed.**

## Use case

Multi-tenant cluster where multiple ServiceAccounts share a namespace, but only one specific SA should be allowed to run a sensitive task (e.g., production deploy). Namespace-level authorization is too coarse — every SA in `platform` can run prod deploys, not just `platform/deployer`.

## Proposal

Add a complementary `allowed_users` field to `TaskDef`, matched against the identity header (`X-Forwarded-User`, configurable via `AQSH_IDENTITY_HEADER`):

```yaml
tasks:
  prod-deploy:
    script: deploy.sh
    allowed_users:
      - "system:serviceaccount:platform:deployer"
    allowed_groups:
      - "system:serviceaccounts:platform-admin"   # OR-combined with allowed_users
```

Semantics: a request passes if it matches **any** entry in either list (OR). When `allowed_users` is empty, behavior is identical to today's `allowed_groups`-only check, so this is fully backward-compatible.

### Optional follow-up: federation awareness

When [`kube-federated-auth`](https://github.com/rophy/kube-federated-auth) is used, kube-auth-proxy adds `X-Forwarded-Extra-Cluster-Name`. Same-named SAs across clusters currently collide (cluster-A's `platform/deployer` and cluster-B's `platform/deployer` are indistinguishable to aqsh). A future enhancement could match on `(cluster, user)` for cross-cluster setups — but that can be a separate issue.

## Sketch of changes

- `internal/tasks/tasks.go` (TaskDef): add `AllowedUsers []string` with `yaml:"allowed_users"`
- `internal/api/api.go` (around the existing `hasAnyGroup` check): add a parallel identity check, OR-combined with the groups check
- `internal/api/api_test.go`: cases for users-only, groups-only, both (OR), neither (open)
- `README.md` / `docs/api.md`: document `allowed_users` in the authorization section

Happy to send a PR if you're open to this direction.
