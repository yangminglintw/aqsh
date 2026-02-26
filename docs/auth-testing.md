# Testing Authentication with kube-auth-proxy

aqsh uses [kube-auth-proxy](https://github.com/rophy/kube-auth-proxy) as a sidecar to authenticate requests using Kubernetes ServiceAccount (SA) tokens. This guide covers how to test the authentication flow via port-forwarding.

## Prerequisites

- `kubectl` access to the cluster where aqsh is deployed
- aqsh deployed in the `aqsh` namespace (see [k8s/](../k8s/))

## Setup: Port-Forward to aqsh

The aqsh Service listens on port 8080, which maps to kube-auth-proxy on port 4180. Port-forward to the service:

```bash
kubectl --context=<CTX> -n aqsh port-forward svc/aqsh 8080:8080
```

All requests to `localhost:8080` now go through kube-auth-proxy, which validates the Bearer token via the Kubernetes TokenReview API before proxying to aqsh.

## Getting a ServiceAccount Token

### Method 1: `kubectl create token` (recommended for local testing)

Generate a short-lived token for any ServiceAccount:

```bash
# Token for the aqsh SA (default, no special groups)
TOKEN=$(kubectl --context=<CTX> -n aqsh create token aqsh)

# Token for an SA in another namespace (groups will include system:serviceaccounts:<namespace>)
TOKEN=$(kubectl --context=<CTX> -n deploy create token deployer)
```

The token expires after 1 hour by default. Use `--duration=10m` for shorter-lived tokens.

### Method 2: Read token from inside a Pod

If you have a shell in a Pod that mounts an SA token:

```bash
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
```

This is useful when testing from within the cluster (e.g., from a debug pod or another workload).

### Comparison

| | Method 1: `kubectl create token` | Method 2: Pod-mounted token |
|---|---|---|
| **Use case** | Local machine testing | In-cluster testing |
| **Requires** | `kubectl` + cluster access | Shell in a Pod |
| **Token lifetime** | Configurable (default 1h) | Auto-rotated by kubelet |
| **Flexibility** | Any SA in any namespace | Only the Pod's own SA |

## Testing Requests

### Without a token (expect 401)

```bash
curl -s http://localhost:8080/health
```

Expected response:

```
Unauthorized
```

HTTP status: **401**

### With a valid token (expect 200)

```bash
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:8080/health
```

Expected response:

```json
{
  "status": "healthy",
  "version": "0.1.0",
  "redis": "connected",
  "mode": "both"
}
```

### List available tasks

```bash
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:8080/tasks | jq .
```

### Submit a task

```bash
curl -s -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "world"}' \
  http://localhost:8080/tasks/hello
```

Expected response (202):

```json
{
  "id": "task_...",
  "queue": "default",
  "status": "pending"
}
```

### Submit a task with group restriction

The `deploy` task requires `allowed_groups: ["system:serviceaccounts:deploy"]`. To test this, create a token from an SA in the `deploy` namespace:

```bash
# This token's groups include system:serviceaccounts:deploy
DEPLOY_TOKEN=$(kubectl --context=<CTX> -n deploy create token deployer)

curl -s -X POST \
  -H "Authorization: Bearer $DEPLOY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"version": "1.0.0", "environment": "dev", "dry_run": "true"}' \
  http://localhost:8080/tasks/deploy
```

Using the default `aqsh` SA token would return **403** because its groups (`system:serviceaccounts:aqsh`) don't match.

## Troubleshooting

### 401 Unauthorized on every request

- Verify the token is valid: `kubectl --context=<CTX> auth can-i --list --token="$TOKEN"` should work without errors.
- Check that the `aqsh` ServiceAccount has the `aqsh-token-reviewer` ClusterRoleBinding (see [k8s/auth.yaml](../k8s/auth.yaml)). Without it, kube-auth-proxy cannot validate tokens via TokenReview.
- Ensure you're port-forwarding to the correct port (`svc/aqsh 8080:8080`, not directly to the pod's 8080 which bypasses the proxy).

### 403 Forbidden on a specific task

- The task has `allowed_groups` configured. Check which groups your token provides:
  ```bash
  kubectl --context=<CTX> create token <sa-name> -n <namespace> -o jsonpath='{.status}'
  ```
  SA tokens automatically include `system:serviceaccounts` and `system:serviceaccounts:<namespace>` as groups.
- Ensure the `allowed_groups` value in `tasks.yaml` matches one of these groups.

### Connection refused on port-forward

- Verify the aqsh pod is running: `kubectl --context=<CTX> -n aqsh get pods`
- Check kube-auth-proxy container logs: `kubectl --context=<CTX> -n aqsh logs deploy/aqsh -c kube-auth-proxy`
- Check aqsh container logs: `kubectl --context=<CTX> -n aqsh logs deploy/aqsh -c aqsh`

### Token expired

`kubectl create token` tokens expire after 1 hour by default. Generate a new one:

```bash
TOKEN=$(kubectl --context=<CTX> -n aqsh create token aqsh)
```
