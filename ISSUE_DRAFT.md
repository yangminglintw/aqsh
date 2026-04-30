# Authorization: `allowed_groups` cannot restrict a task to a single ServiceAccount

## Summary

`allowed_groups` does exact-string match against `X-Forwarded-Groups`. With realistic Kubernetes credentials forwarded by a TokenReview-based proxy (e.g. [`kube-auth-proxy`](https://github.com/rophy/kube-auth-proxy)), the smallest unit of authorization that can ever be expressed is the **namespace** of a ServiceAccount. There is no value of `X-Forwarded-Groups` that any such proxy will produce that authorizes a specific SA — so a task today cannot be restricted to, say, `platform/deployer` while excluding other SAs in the `platform` namespace.

This is not a configuration error or a documentation gap. The current data model (groups-only allowlist) cannot express per-SA authorization at all.

## Current behavior

- `internal/api/api.go` reads `X-Forwarded-Groups` and runs `hasAnyGroup` (pure `==` comparison).
- `X-Forwarded-User` is read into `identity` but only used for access logging and stored on the task payload for audit. It is never compared against any allowlist.

## Expected behavior

It should be possible to author a task that allows exactly one Kubernetes ServiceAccount (e.g., `system:serviceaccount:platform:deployer`) and rejects all other SAs — including other SAs in the same namespace. The authorization model needs a way to address identity, not only group membership.

## Why this matters

Kubernetes TokenReview returns a fixed set of groups for a SA token:

- `system:serviceaccounts`
- `system:serviceaccounts:<namespace>`
- `system:authenticated`

The full SA identifier `system:serviceaccount:<ns>:<name>` is returned as the username, never as a group. See the upstream documentation: [Service account tokens](https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/#bound-service-account-tokens) and [RBAC — Service account permissions](https://kubernetes.io/docs/reference/access-authn-authz/rbac/#service-account-permissions).

Therefore the limitation is structural: any allowlist that only consults `X-Forwarded-Groups` is fundamentally namespace-coarse for SA traffic.

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

A and B confirm that the `allowed_groups` matcher works correctly. C is the gap.

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

## Possible approach

I don't want to pre-commit you to a particular design. The simplest extension that closes the gap is a complementary identity allowlist matched against `X-Forwarded-User` (e.g., an `allowed_users` field, OR-combined with `allowed_groups` to mirror Kubernetes RBAC `RoleBinding.subjects` semantics). Other shapes — a unified `subjects:` list, a CEL/expression-based matcher, etc. — would also work; I'm happy to align with whatever direction you prefer.

I'm willing to open a PR once the desired shape is agreed.

<details>
<summary>Sketch of one minimal implementation (only if useful — not a recommendation)</summary>

- `internal/tasks/tasks.go`: add `AllowedUsers []string` to `TaskDef` (`yaml:"allowed_users"`)
- `internal/api/api.go`: parallel identity check next to the existing `hasAnyGroup` call, OR-combined
- `internal/api/api_test.go`: cases for users-only, groups-only, both, neither
- README / `docs/api.md`: document the new field

</details>

---

_Out of scope for this issue, but noted for context:_ when [`kube-federated-auth`](https://github.com/rophy/kube-federated-auth) is used, same-named SAs across clusters share the same `X-Forwarded-User` value. Cross-cluster disambiguation would need `X-Forwarded-Extra-Cluster-Name` to participate in the match — a topic for a separate issue.
