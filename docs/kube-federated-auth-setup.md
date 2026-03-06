# Setting Up kube-federated-auth for Cross-Cluster Token Validation

## Overview

By default, aqsh uses [kube-auth-proxy](https://github.com/rophy/kube-auth-proxy) as a sidecar that validates ServiceAccount tokens via the local cluster's TokenReview API. This requires a `tokenreviews` ClusterRoleBinding (see [k8s/auth.yaml](../k8s/auth.yaml)).

[kube-federated-auth](https://github.com/rophy/kube-federated-auth) is an alternative that provides a centralized TokenReview service capable of validating tokens from multiple Kubernetes clusters. kube-auth-proxy delegates token validation to it via `--token-review-url`.

```
                         ┌──────────────────────────┐
                         │      Remote Cluster B     │
                         │   (token issuer)          │
                         │                           │
                         │  SA token ──► TokenReview  │
                         │              API Server    │
                         └────────────▲───────────────┘
                                      │
┌──────────────────────────────────────┼──────────────────────────┐
│  Local Cluster (where aqsh runs)     │                          │
│                                      │                          │
│  Client ─► kube-auth-proxy ─► kube-federated-auth               │
│              (sidecar)         --token-review-url                │
│                                      │                          │
│                                      ├──► Local K8s API Server  │
│                                      │    (for local tokens)    │
│                                      │                          │
│                                      └──► OIDC/JWKS discovery   │
│                                           (for public issuers)  │
└─────────────────────────────────────────────────────────────────┘
```

### When to use each mode

| Mode | Use case |
|------|----------|
| **Standalone** (default) | Single cluster, you can create a `tokenreviews` ClusterRoleBinding |
| **Federated** | Multi-cluster token validation, or environments where ClusterRoleBindings are restricted |

---

## Prerequisites

**With kubeconfig access (no admin required):**

- `kubectl` access to the **local cluster** (where aqsh runs)
- `kubectl` access to the **remote cluster(s)** — enough to read kubeconfig, exec into pods, and decode SA tokens
- Get the API server address and CA cert from kubeconfig
- Get the OIDC issuer URL by decoding any SA token's JWT payload (see Step 1a)

**Requires cluster admin on the remote cluster:**

- Create the ServiceAccount, ClusterRole/ClusterRoleBinding, and Role/RoleBinding (Step 1d)
- Generate a bootstrap token for the ServiceAccount (Step 1e)

**Network requirement:**

- The remote cluster's OIDC issuer must be reachable from kube-federated-auth, or you provide `api_server` + `ca_cert` for private clusters

---

## Step 1: Gather Remote Cluster Credentials

For each remote cluster you want to validate tokens from, gather the following. All commands target the **remote** cluster.

> **Navigation:** Steps 1a–1c are read-only operations — you can do these yourself with kubeconfig access. Steps 1d–1e require cluster admin permissions.

### 1a. Get the OIDC issuer URL

**Option 1: Query the OIDC discovery endpoint**

```bash
kubectl --context=<REMOTE_CTX> get --raw /.well-known/openid-configuration | jq -r '.issuer'
```

**Option 2: Decode from a ServiceAccount token (when the discovery endpoint returns 403 Forbidden)**

If you have a pod running in the remote cluster, extract the issuer from its mounted SA token:

```bash
kubectl --context=<REMOTE_CTX> exec <POD_NAME> -n <NAMESPACE> -- \
  cat /var/run/secrets/kubernetes.io/serviceaccount/token \
  | cut -d. -f2 | base64 -d 2>/dev/null | jq -r '.iss'
```

**Option 3: Cloud provider CLI**

```bash
# EKS
aws eks describe-cluster --name <CLUSTER_NAME> --query 'cluster.identity.oidc.issuer' --output text

# GKE
gcloud container clusters describe <CLUSTER_NAME> --zone <ZONE> --format='value(selfLink)'

# AKS
az aks show --resource-group <RG> --name <CLUSTER_NAME> --query 'oidcIssuerProfile.issuerUrl' -o tsv
```

**Option 4:** Ask the cluster admin team for the issuer URL.

Save this value — it goes into `clusters.yaml` as the `issuer` field.

### 1b. Get the API server address (private clusters only)

If the issuer URL is not publicly reachable (e.g., `https://kubernetes.default.svc.cluster.local`), you need the external API server address:

```bash
kubectl --context=<REMOTE_CTX> config view --minify -o jsonpath='{.clusters[0].cluster.server}'
```

### 1c. Extract the CA certificate (private clusters only)

The CA cert is needed when `api_server` points to a private endpoint with a self-signed certificate.

Check which format your kubeconfig uses — either inline base64 data (`certificate-authority-data`) or a file path (`certificate-authority`):

```bash
# Check which field is set
kubectl --context=<REMOTE_CTX> config view --minify -o json \
  | jq '.clusters[0].cluster | keys'
```

**If `certificate-authority-data` (inline base64):**

```bash
kubectl --context=<REMOTE_CTX> config view --minify --raw \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > cluster-b-ca.crt
```

**If `certificate-authority` (file path):**

```bash
CA_PATH=$(kubectl --context=<REMOTE_CTX> config view --minify \
  -o jsonpath='{.clusters[0].cluster.certificate-authority}')
cp "$CA_PATH" cluster-b-ca.crt
```

**Alternative: Extract from a running pod**

If you have a pod running in the remote cluster, you can copy the CA cert from the pod's mounted service account:

```bash
kubectl --context=<REMOTE_CTX> exec <POD_NAME> -n <NAMESPACE> -- \
  cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt > cluster-b-ca.crt
```

### 1d. Create a ServiceAccount on the remote cluster

> **No admin access?** Send the YAML below to the remote cluster's admin team and ask them to apply it.

This SA is used by kube-federated-auth to validate tokens and renew its own credentials on the remote cluster.

```bash
kubectl --context=<REMOTE_CTX> create namespace kube-federated-auth

kubectl --context=<REMOTE_CTX> -n kube-federated-auth create serviceaccount kube-federated-auth
```

Grant the SA permission to create TokenReviews (for token validation) and TokenRequests (for credential renewal):

```yaml
# remote-rbac.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kube-federated-auth
rules:
- apiGroups: ["authentication.k8s.io"]
  resources: ["tokenreviews"]
  verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kube-federated-auth
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kube-federated-auth
subjects:
- kind: ServiceAccount
  name: kube-federated-auth
  namespace: kube-federated-auth
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: kube-federated-auth-token
  namespace: kube-federated-auth
rules:
- apiGroups: [""]
  resources: ["serviceaccounts/token"]
  verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: kube-federated-auth-token
  namespace: kube-federated-auth
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: kube-federated-auth-token
subjects:
- kind: ServiceAccount
  name: kube-federated-auth
  namespace: kube-federated-auth
```

```bash
kubectl --context=<REMOTE_CTX> apply -f remote-rbac.yaml
```

### 1e. Generate a bootstrap token

> **No admin access?** Ask the admin who created the ServiceAccount in Step 1d to run the command below and send you the token output.

This short-lived token bootstraps kube-federated-auth's access to the remote cluster. Once running, it uses TokenRequest to renew its own credentials automatically.

```bash
kubectl --context=<REMOTE_CTX> -n kube-federated-auth create token kube-federated-auth --duration=1h
```

Save this token — you'll create a Secret with it in the next step. Use it promptly since it expires in 1 hour.

---

## Step 2: Create Kubernetes Resources on the Local Cluster

All commands in this step target the **local** cluster (where aqsh runs).

### 2a. Create a Secret for the bootstrap token

The bootstrap token is sensitive — store it in a Secret:

```yaml
# kube-federated-auth-creds.yaml
apiVersion: v1
kind: Secret
metadata:
  name: kube-federated-auth-creds
  namespace: aqsh
type: Opaque
stringData:
  cluster-b-token: "<BOOTSTRAP_TOKEN>"
```

```bash
kubectl --context=<LOCAL_CTX> apply -f kube-federated-auth-creds.yaml
```

### 2b. Create a ConfigMap for clusters.yaml and CA certificate

The CA certificate is not sensitive (it's a public key), so it goes in the ConfigMap alongside the cluster configuration:

```yaml
# kube-federated-auth-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-federated-auth-config
  namespace: aqsh
data:
  clusters.yaml: |
    clusters:
      cluster-b:
        issuer: "https://kubernetes.default.svc.cluster.local"
        api_server: "https://192.168.1.100:6443"
        ca_cert: "/etc/kube-federated-auth/config/cluster-b-ca.crt"
        token_path: "/etc/kube-federated-auth/tokens/cluster-b-token"

    renewal:
      interval: "1h"
      token_duration: "168h"
      renew_before: "48h"
  cluster-b-ca.crt: |
    -----BEGIN CERTIFICATE-----
    <paste contents of cluster-b-ca.crt here>
    -----END CERTIFICATE-----
```

```bash
kubectl --context=<LOCAL_CTX> apply -f kube-federated-auth-config.yaml
```

### Path mapping reference

Understanding how ConfigMap/Secret keys become file paths inside the Pod:

```
Layer 1: Resource                 Layer 2: Volume mount             Layer 3: Config reference
────────────────                  ──────────────────────             ──────────────────────────
ConfigMap key                     mountPath / key-name              clusters.yaml field
───────────────────────────────────────────────────────────────────────────────────────────────
cluster-b-ca.crt          ──►     /etc/kube-federated-auth/config/  ca_cert:
                                    cluster-b-ca.crt                  "/etc/kube-federated-auth/config/cluster-b-ca.crt"

Secret key                        mountPath / key-name              clusters.yaml field
───────────────────────────────────────────────────────────────────────────────────────────────
cluster-b-token           ──►     /etc/kube-federated-auth/tokens/  token_path:
                                    cluster-b-token                   "/etc/kube-federated-auth/tokens/cluster-b-token"
```

The CA certificate is stored in the ConfigMap (non-sensitive), while the bootstrap token is stored in the Secret (sensitive). The Deployment mounts each resource as a separate volume.

---

## Step 3: Deploy kube-federated-auth

```yaml
# kube-federated-auth.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kube-federated-auth
  namespace: aqsh
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: kube-federated-auth
  namespace: aqsh
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "create", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: kube-federated-auth
  namespace: aqsh
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: kube-federated-auth
subjects:
- kind: ServiceAccount
  name: kube-federated-auth
  namespace: aqsh
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kube-federated-auth
  namespace: aqsh
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kube-federated-auth
  template:
    metadata:
      labels:
        app: kube-federated-auth
    spec:
      serviceAccountName: kube-federated-auth
      containers:
      - name: kube-federated-auth
        image: ghcr.io/rophy/kube-federated-auth:latest
        env:
        - name: CONFIG_PATH
          value: /etc/kube-federated-auth/config/clusters.yaml
        - name: PORT
          value: "8080"
        - name: SECRET_NAME
          value: kube-federated-auth
        ports:
        - containerPort: 8080
        volumeMounts:
        - name: config
          mountPath: /etc/kube-federated-auth/config
        - name: tokens
          mountPath: /etc/kube-federated-auth/tokens
        readinessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 3
          periodSeconds: 5
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 10
        resources:
          requests:
            memory: "32Mi"
            cpu: "50m"
          limits:
            memory: "64Mi"
            cpu: "100m"
      volumes:
      - name: config
        configMap:
          name: kube-federated-auth-config
      - name: tokens
        secret:
          secretName: kube-federated-auth-creds
---
apiVersion: v1
kind: Service
metadata:
  name: kube-federated-auth
  namespace: aqsh
spec:
  selector:
    app: kube-federated-auth
  ports:
  - port: 8080
    targetPort: 8080
```

```bash
kubectl --context=<LOCAL_CTX> apply -f kube-federated-auth.yaml
```

The Role grants kube-federated-auth permission to read and write Secrets in the `aqsh` namespace. It uses this to persist renewed tokens so they survive Pod restarts.

---

## Step 4: Connect kube-auth-proxy

Update the kube-auth-proxy container args in the aqsh Deployment to point to kube-federated-auth:

```yaml
containers:
- name: kube-auth-proxy
  image: ghcr.io/rophy/kube-auth-proxy:latest
  args:
  - --upstream=http://localhost:8080
  - --port=4180
  - --token-review-url=http://kube-federated-auth.aqsh.svc.cluster.local:8080
```

With `--token-review-url` set, kube-auth-proxy sends TokenReview requests to kube-federated-auth instead of the local Kubernetes API server. This means:

- The aqsh ServiceAccount **no longer needs** the `tokenreviews` ClusterRoleBinding from [k8s/auth.yaml](../k8s/auth.yaml)
- You can remove the `aqsh-token-reviewer` ClusterRole and ClusterRoleBinding

---

## Step 5: Verify

### 5a. Check kube-federated-auth health

```bash
kubectl --context=<LOCAL_CTX> -n aqsh port-forward svc/kube-federated-auth 9090:8080

curl -s http://localhost:9090/health | jq .
```

Expected:

```json
{
  "status": "ok",
  "version": "..."
}
```

### 5b. Check cluster status

```bash
curl -s http://localhost:9090/clusters | jq .
```

This shows all configured clusters and their token status (`valid`, `expiring_soon`, `expired`, or `unknown`).

### 5c. Test end-to-end

Generate a token from the **remote** cluster and use it to call aqsh through kube-auth-proxy:

```bash
# Generate a token on the remote cluster
TOKEN=$(kubectl --context=<REMOTE_CTX> -n kube-federated-auth create token kube-federated-auth)

# Port-forward to aqsh (goes through kube-auth-proxy)
kubectl --context=<LOCAL_CTX> -n aqsh port-forward svc/aqsh 8080:8080

# Test with the remote cluster's token
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:8080/health | jq .
```

If authentication succeeds, you'll get the aqsh health response. A `401` means kube-federated-auth could not validate the token — check its logs:

```bash
kubectl --context=<LOCAL_CTX> -n aqsh logs deploy/kube-federated-auth
```

---

## Config Reference

### clusters.yaml fields

#### Top-level

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `clusters` | map | — | Map of cluster name to cluster config |
| `authorized_clients` | []string | — | Whitelist of callers in `cluster/namespace/sa` format (supports `*` wildcard). If unset, all callers are allowed |
| `renewal.interval` | duration | `1h` | How often to check and renew tokens |
| `renewal.token_duration` | duration | `168h` | Requested TTL for renewed tokens |
| `renewal.renew_before` | duration | `48h` | Renew when remaining TTL is less than this |
| `cache.ttl` | int | `0` | Global TokenReview response cache TTL in seconds (0 = disabled) |
| `cache.max_entries` | int | `0` | Global cache size limit (0 = disabled) |
| `log_level` | string | `INFO` | `DEBUG`, `INFO`, `WARN`, `ERROR` |

#### Per-cluster

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `issuer` | string | Yes | OIDC issuer URL for JWKS discovery |
| `api_server` | string | No | API server address. Setting this enables remote mode (token renewal) |
| `ca_cert` | string | No | Path to CA certificate file for the API server |
| `token_path` | string | No | Path to bootstrap token file. Only read when no persisted token exists |
| `cache.ttl` | int | No | Per-cluster cache TTL override (seconds) |
| `cache.max_entries` | int | No | Per-cluster cache size override |

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CONFIG_PATH` | `config/clusters.yaml` | Path to clusters.yaml |
| `PORT` | `8080` | HTTP listen port |
| `SECRET_NAME` | `kube-federated-auth` | K8s Secret name for persisting renewed tokens |

### Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | Health check |
| `GET` | `/clusters` | List clusters and token status |
| `POST` | `/apis/authentication.k8s.io/v1/tokenreviews` | TokenReview API (K8s-compatible) |

### Notes

#### Multi-cluster setup

To validate tokens from multiple remote clusters, add each cluster's CA cert to the ConfigMap and each bootstrap token to the Secret:

```yaml
# kube-federated-auth-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-federated-auth-config
  namespace: aqsh
data:
  clusters.yaml: |
    clusters:
      cluster-a:
        issuer: "https://kubernetes.default.svc.cluster.local"
        api_server: "https://10.0.1.100:6443"
        ca_cert: "/etc/kube-federated-auth/config/cluster-a-ca.crt"
        token_path: "/etc/kube-federated-auth/tokens/cluster-a-token"
      cluster-b:
        issuer: "https://kubernetes.default.svc.cluster.local"
        api_server: "https://10.0.2.100:6443"
        ca_cert: "/etc/kube-federated-auth/config/cluster-b-ca.crt"
        token_path: "/etc/kube-federated-auth/tokens/cluster-b-token"
      cluster-c:
        issuer: "https://oidc.eks.us-west-2.amazonaws.com/id/EXAMPLE"
        # Public OIDC issuer — no api_server or ca_cert needed
        token_path: "/etc/kube-federated-auth/tokens/cluster-c-token"

    renewal:
      interval: "1h"
      token_duration: "168h"
      renew_before: "48h"
  cluster-a-ca.crt: |
    -----BEGIN CERTIFICATE-----
    <paste cluster-a CA cert here>
    -----END CERTIFICATE-----
  cluster-b-ca.crt: |
    -----BEGIN CERTIFICATE-----
    <paste cluster-b CA cert here>
    -----END CERTIFICATE-----
```

```yaml
# kube-federated-auth-creds.yaml
apiVersion: v1
kind: Secret
metadata:
  name: kube-federated-auth-creds
  namespace: aqsh
type: Opaque
stringData:
  cluster-a-token: "<CLUSTER_A_BOOTSTRAP_TOKEN>"
  cluster-b-token: "<CLUSTER_B_BOOTSTRAP_TOKEN>"
  cluster-c-token: "<CLUSTER_C_BOOTSTRAP_TOKEN>"
```

No Deployment changes are needed — the ConfigMap volume at `/config/` and Secret volume at `/tokens/` automatically include all keys as files.

Clusters with a public OIDC issuer (e.g., EKS) don't need `api_server` or `ca_cert` — kube-federated-auth discovers the JWKS endpoint via the issuer URL directly.

#### Multiple clusters with the same issuer URL

Multiple remote clusters can share the same default issuer (e.g., `https://kubernetes.default.svc.cluster.local`). This works correctly as long as each cluster entry has a different `api_server`:

- Different `api_server` values → different JWKS endpoints → different signing keys (KIDs) → kube-federated-auth matches tokens to the correct cluster
- Without `api_server`, clusters sharing an issuer will be ambiguous and may cause incorrect cluster attribution during token validation
