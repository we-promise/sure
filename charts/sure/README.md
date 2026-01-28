# Sure Helm Chart

Official Helm chart for deploying the Sure Rails application on Kubernetes. It supports web (Rails) and worker (Sidekiq) workloads, optional in-cluster PostgreSQL (CloudNativePG) and Redis subcharts for turnkey self-hosting, and production-grade features like pre-upgrade migrations, pod security contexts, HPAs, and optional ServiceMonitor.

## Features

- Web (Rails) Deployment + Service and optional Ingress
- Worker (Sidekiq) Deployment
- Optional Helm-hook Job for db:migrate, or initContainer migration strategy
- Optional post-install/upgrade SimpleFin encryption backfill Job (idempotent; dry-run by default)
- Optional CronJobs for custom tasks
- Optional subcharts
  - CloudNativePG (operator) + Cluster CR for PostgreSQL with HA support
  - OT-CONTAINER-KIT redis-operator for Redis HA (replication by default, optional Sentinel)
- Security best practices: runAsNonRoot, readOnlyRootFilesystem, optional existingSecret, no hardcoded secrets
- Scalability
  - Replicas (web/worker), resources, topology spread constraints
  - Optional HPAs for web/worker
  - Affinity, nodeSelector, tolerations

## Requirements

- Kubernetes >= 1.25
- Helm >= 3.10
- For subcharts: add repositories first
  ```sh
  helm repo add cloudnative-pg https://cloudnative-pg.github.io/charts
  helm repo add ot-helm https://ot-container-kit.github.io/helm-charts
  helm repo update
  ```

## Quickstart (turnkey self-hosting)

This installs CNPG operator + a Postgres cluster and Redis managed by the OT redis-operator (replication mode by default). It also creates an app Secret if you provide values under `rails.secret.values` (recommended for quickstart only; prefer an existing Secret or External Secrets in production).

Important: For production stability, use immutable image tags (for example, set `image.tag=v1.2.3`) instead of `latest`.

```sh
# Namespace
kubectl create ns sure || true

# Install chart (example: provide SECRET_KEY_BASE and pin an immutable image tag)
helm upgrade --install sure charts/sure \
  -n sure \
  --set image.tag=v1.2.3 \
  --set rails.secret.enabled=true \
  --set rails.secret.values.SECRET_KEY_BASE=$(openssl rand -hex 32)
```

Expose the app via an Ingress (see values) or `kubectl port-forward svc/sure 8080:80 -n sure`.

## Using external Postgres/Redis

Disable the bundled CNPG/Redis resources and set URLs explicitly.

```yaml
cnpg:
  enabled: false

redisOperator:
  managed:
    enabled: false

redisSimple:
  enabled: false

rails:
  extraEnv:
    DATABASE_URL: postgresql://user:pass@db.example.com:5432/sure
    REDIS_URL: redis://:pass@redis.example.com:6379/0
```

## Installation profiles

### Deployment modes

| Mode                         | Description                               | Key values                                                                 |
|------------------------------|-------------------------------------------|----------------------------------------------------------------------------|
| Simple single-node           | All-in-one, minimal HA                    | `cnpg.cluster.instances=1`, `redisOperator.mode=replication`               |
| HA self-hosted (replication) | CNPG + RedisReplication spread over nodes | `cnpg.cluster.instances=3`, `redisOperator.mode=replication`               |
| HA self-hosted (Sentinel)    | Replication + Sentinel failover layer     | `redisOperator.mode=sentinel`, `redisOperator.sentinel.enabled=true`       |
| External DB/Redis            | Use managed Postgres/Redis                | `cnpg.enabled=false`, `redisOperator.managed.enabled=false`, set URLs envs |

Below are example value stubs you can start from, depending on whether you want a simple single-node setup or a more HA-oriented k3s cluster.

### Simple single-node / low-resource profile

```yaml
image:
  repository: ghcr.io/we-promise/sure
  tag: "v1.0.0"          # pin a specific version in production
  pullPolicy: IfNotPresent

rails:
  existingSecret: sure-secrets
  encryptionEnv:
    enabled: true
  settings:
    SELF_HOSTED: "true"

cnpg:
  enabled: true
  cluster:
    enabled: true
    name: sure-db
    instances: 1
    storage:
      size: 8Gi
      storageClassName: longhorn

redisOperator:
  enabled: true
  managed:
    enabled: true
  mode: replication
  sentinel:
    enabled: false
  replicas: 3
  persistence:
    enabled: true
    className: longhorn
    size: 8Gi

migrations:
  strategy: job

simplefin:
  encryption:
    enabled: false         # enable + backfill later once you're happy
    backfill:
      enabled: true
      dryRun: true
```

### HA k3s profile (example)

```yaml
cnpg:
  enabled: true
  cluster:
    enabled: true
    name: sure-db
    instances: 3
    storage:
      size: 20Gi
      storageClassName: longhorn
    # Optional: enable CNPG volume snapshot backups (requires a VolumeSnapshotClass)
    backup:
      method: volumeSnapshot
      volumeSnapshot:
        className: longhorn
    # Synchronous replication for stronger durability
    minSyncReplicas: 1
    maxSyncReplicas: 2
    # Spread CNPG instances across nodes (adjust selectors for your cluster)
    topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: ScheduleAnyway
        labelSelector:
          matchLabels:
            cnpg.io/cluster: sure-db

redisOperator:
  enabled: true
  managed:
    enabled: true
  mode: replication
  sentinel:
    enabled: false
  replicas: 3
  persistence:
    enabled: true
    className: longhorn
    size: 8Gi

migrations:
  strategy: job
  initContainer:
    enabled: true   # optional safety net on pod restarts (only migrates when pending)

simplefin:
  encryption:
    enabled: true
    backfill:
      enabled: true
      dryRun: false
```

## CloudNativePG notes

- The chart configures credentials via `spec.bootstrap.initdb.secret` rather than `managed.roles`. The operator expects the referenced Secret to contain `username` and `password` keys (configurable via values).
- This chart generates the application DB Secret when `cnpg.cluster.secret.enabled=true` using the keys defined at `cnpg.cluster.secret.usernameKey` (default `username`) and `cnpg.cluster.secret.passwordKey` (default `password`). If you use an existing Secret (`cnpg.cluster.existingSecret`), ensure it contains these keys. The Cluster CR references the Secret by name and maps the keys accordingly.
- If the CNPG operator is already installed cluster‑wide, you may set `cnpg.enabled=false` and keep `cnpg.cluster.enabled=true`. The chart will still render the `Cluster` CR and compute the in‑cluster `DATABASE_URL`.
- For backups, CNPG requires `spec.backup.method` to be explicit (for example `volumeSnapshot` or `barmanObjectStore`). This chart will infer `method: volumeSnapshot` if a `backup.volumeSnapshot` block is present.
  - For snapshot backups, `backup.volumeSnapshot.className` must be set (the chart will fail the render if it is missing).
  - The CNPG `spec.backup` schema does not support keys like `ttl` or `volumeSnapshot.enabled`; this chart strips those keys to avoid CRD warnings.
  - Unknown `backup.method` values are passed through and left for CNPG to validate.

Example (barman-cloud plugin for WAL archiving + snapshot backups):

```yaml
cnpg:
  cluster:
    plugins:
      - name: barman-cloud.cloudnative-pg.io
        isWALArchiver: true
        parameters:
          barmanObjectName: minio-backups  # references an ObjectStore CR
    backup:
      method: volumeSnapshot
      volumeSnapshot:
        className: longhorn
```

Additional default hardening:

- `DATABASE_URL` includes `?sslmode=prefer`.
- Init migrations run `db:create || true` before `db:migrate` for first‑boot convenience.

## Redis URL and authentication

- When the OT redis-operator is used via this chart (see `redisOperator.managed.enabled=true`), `REDIS_URL` resolves to the operator's stable master service. In shell contexts, this can be expressed as:
  - `redis://default:$(REDIS_PASSWORD)@<name>-redis-master.<namespace>.svc.cluster.local:6379/0` (where `<name>` defaults to `<fullname>-redis` but is overrideable via `redisOperator.name`)
  For Kubernetes manifests, do not inline shell expansion. Either let this chart construct `REDIS_URL` for you automatically (recommended), or use a literal form with a placeholder password, e.g.:
  - `redis://default:<password>@<name>-redis-master.<namespace>.svc.cluster.local:6379/0`
- The `default` username is required with Redis 6+ ACLs. If you explicitly set `REDIS_URL` under `rails.extraEnv`, your value takes precedence.
- The Redis password is taken from `sure.redisSecretName` (typically your app Secret, e.g. `sure-secrets`) using the key returned by `sure.redisPasswordKey` (default `redis-password`).
- If you prefer a simple (non‑HA) in‑cluster Redis, disable the operator-managed Redis (`redisOperator.managed.enabled=false`) and enable `redisSimple.enabled`. The chart will deploy a single Redis Pod + Service and wire `REDIS_URL` accordingly. Provide a password via `redisSimple.auth.existingSecret` (recommended) or rely on your app secret mapping.

### Using the OT redis-operator (Sentinel)

This chart can optionally install the OT-CONTAINER-KIT Redis Operator and/or render a `RedisSentinel` CR to manage Redis HA with Sentinel. This approach avoids templating pitfalls and provides stable failover.

Quickstart example (Sentinel, 3 replicas, Longhorn storage, reuse `sure-secrets` password):

```yaml
redisOperator:
  enabled: true              # install operator subchart (or leave false if already installed cluster-wide)
  operator:
    resources:               # optional: keep the operator light on small k3s nodes
      requests:
        cpu: 50m
        memory: 128Mi
      limits:
        cpu: 100m
        memory: 256Mi
  managed:
    enabled: true            # render Redis CRs for in-cluster Redis
  mode: sentinel             # enables RedisSentinel CR in addition to RedisReplication
  sentinel:
    enabled: true            # must be true when mode=sentinel
    masterGroupName: mymaster
  name: ""                   # defaults to <fullname>-redis
  replicas: 3
  auth:
    existingSecret: sure-secrets
    passwordKey: redis-password
  persistence:
    className: longhorn
    size: 8Gi
```

Notes:
- When `redisOperator.mode=sentinel` and `redisOperator.sentinel.enabled=true`, the chart automatically configures Sidekiq to use Redis Sentinel for high availability.
- The application receives `REDIS_SENTINEL_HOSTS` (comma-separated list of Sentinel endpoints) and `REDIS_SENTINEL_MASTER` (master group name) environment variables instead of `REDIS_URL`.
- Sidekiq will connect to Sentinel nodes for automatic master discovery and failover support.
- Both the Redis master and Sentinel nodes use the same password from `REDIS_PASSWORD` (via `redisOperator.auth.existingSecret`).
- Sentinel authentication uses username "default" by default (configurable via `REDIS_SENTINEL_USERNAME`).
- The operator master service is `<name>-redis-master.<ns>.svc.cluster.local:6379`.
- The CR references your existing password secret via `kubernetesConfig.redisSecret { name, key }`.
- Provider precedence for auto-wiring is: explicit `rails.extraEnv.REDIS_URL` → `redisOperator.managed` (with Sentinel if configured) → `redisSimple`.
- Only one in-cluster Redis provider should be enabled at a time to avoid ambiguity.

### HA scheduling and topology spreading

For resilient multi-node clusters, enforce one pod per node for critical components. Use `topologySpreadConstraints` with `maxSkew: 1` and `whenUnsatisfiable: DoNotSchedule`. Keep selectors precise to avoid matching other apps.

Examples:

```yaml
cnpg:
  cluster:
    instances: 3
    minSyncReplicas: 1
    maxSyncReplicas: 2
    topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels:
            cnpg.io/cluster: sure-db

redisOperator:
  managed:
    enabled: true
    replicas: 3
    topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels:
            app.kubernetes.io/instance: sure  # verify labels on your cluster
```

Security note on label selectors:
- Choose selectors that uniquely match the intended pods to avoid cross-app interference. Good candidates are:
  - CNPG: `cnpg.io/cluster: <cluster-name>` (CNPG labels its pods)
  - RedisReplication: `app.kubernetes.io/instance: <release-name>` or `app.kubernetes.io/name: <cr-name>`

#### Rolling update strategy

When using topology spread constraints with `whenUnsatisfiable: DoNotSchedule`, you must configure the Kubernetes rolling update strategy to prevent deployment deadlocks.

The chart now makes the rolling update strategy configurable for web and worker deployments. The defaults have been changed from Kubernetes defaults (`maxUnavailable=0`, `maxSurge=25%`) to:

```yaml
web:
  strategy:
    rollingUpdate:
      maxUnavailable: 1
      maxSurge: 0

worker:
  strategy:
    rollingUpdate:
      maxUnavailable: 1
      maxSurge: 0
```

**Why these defaults?**

With `maxSurge=0`, Kubernetes will terminate an old pod before creating a new one. This ensures that when all nodes are occupied (due to strict topology spreading), there is always space for the new pod to be scheduled.

If you use `maxSurge > 0` with `DoNotSchedule` topology constraints and all nodes are occupied, Kubernetes cannot create the new pod (no space available) and cannot terminate the old pod (new pod must be ready first), resulting in a deployment deadlock.

**Configuration examples:**

For faster rollouts when not using strict topology constraints:

```yaml
web:
  strategy:
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1

worker:
  strategy:
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
```

For HA setups with topology spreading:

```yaml
web:
  replicas: 3
  strategy:
    rollingUpdate:
      maxUnavailable: 1
      maxSurge: 0
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: kubernetes.io/hostname
      whenUnsatisfiable: DoNotSchedule
      labelSelector:
        matchLabels:
          app.kubernetes.io/name: sure
          app.kubernetes.io/component: web
```

**Warning:** Using `maxSurge > 0` with `whenUnsatisfiable: DoNotSchedule` can cause deployment deadlocks when all nodes are occupied. If you need faster rollouts, either:
- Use `whenUnsatisfiable: ScheduleAnyway` instead of `DoNotSchedule`
- Ensure you have spare capacity on your nodes
- Keep `maxSurge: 0` and accept slower rollouts

Compatibility:
- CloudNativePG v1.27.1 supports `minSyncReplicas`/`maxSyncReplicas` and standard k8s scheduling fields under `spec`.
- OT redis-operator v0.21.0 supports scheduling under `spec.kubernetesConfig`.

Testing and verification:

```bash
# Dry-run render with your values
helm template sure charts/sure -n sure -f ha-values.yaml --debug > rendered.yaml

# Install/upgrade in a test namespace
kubectl create ns sure-test || true
helm upgrade --install sure charts/sure -n sure-test -f ha-values.yaml --wait

# Verify CRs include your scheduling config
kubectl get cluster.postgresql.cnpg.io sure-db -n sure-test -o yaml \
  | yq '.spec | {instances, minSyncReplicas, maxSyncReplicas, nodeSelector, affinity, tolerations, topologySpreadConstraints}'

# Default RedisReplication CR name is <fullname>-redis (e.g., sure-redis) unless overridden by redisOperator.name
kubectl get redisreplication sure-redis -n sure-test -o yaml \
  | yq '.spec.kubernetesConfig | {nodeSelector, affinity, tolerations, topologySpreadConstraints}'

# After upgrade, trigger a gentle reschedule to apply spreads
# CNPG: delete one pod at a time or perform a switchover
kubectl delete pod -n sure-test -l cnpg.io/cluster=sure-db --wait=false --field-selector=status.phase=Running

# RedisReplication: delete one replica pod to let the operator recreate it under new constraints
kubectl delete pod -n sure-test -l app.kubernetes.io/component=redis --wait=false

# Confirm distribution across nodes
kubectl get pods -n sure-test -o wide
```

## Example app Secret (sure-secrets)

You will typically manage secrets via an external mechanism (External Secrets, Sealed Secrets, etc.), but for reference, below is an example `Secret` that provides the keys this chart expects by default:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: sure-secrets
type: Opaque
stringData:
  # Rails secrets
  SECRET_KEY_BASE: "__SET_SECRET__"

  # Active Record Encryption keys (optional but recommended when using encryption features)
  ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY: "__SET_SECRET__"
  ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY: "__SET_SECRET__"
  ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT: "__SET_SECRET__"

  # Redis password used by operator-managed or simple Redis
  redis-password: "__SET_SECRET__"

  # Optional: CNPG bootstrap user/password if you are not letting the chart generate them
  # username: "sure"
  # password: "__SET_SECRET__"
```

Note: These are non-sensitive placeholder values. Do not commit real secrets to version control. Prefer External Secrets, Sealed Secrets, or your platform's secret manager to source these at runtime.

### Linting Helm templates and YAML

Helm template files under `charts/**/templates/**` contain template delimiters like `{{- ... }}` that raw YAML linters will flag as invalid. To avoid false positives in CI:

- Use Helm's linter for charts:
  - `helm lint charts/sure`
- Configure your YAML linter (e.g., yamllint) to ignore Helm template directories (exclude `charts/**/templates/**`), or use a Helm-aware plugin that preprocesses templates before linting.

You can then point the chart at this Secret via:

```yaml
rails:
  existingSecret: sure-secrets

redisOperator:
  managed:
    enabled: true
  auth:
    existingSecret: sure-secrets
    passwordKey: redis-password

cnpg:
  cluster:
    existingSecret: sure-secrets   # if you are reusing the same Secret for DB creds
    secret:
      enabled: false               # do not generate a second Secret when using existingSecret
```

Environment variable ordering for shells:

- The chart declares `DB_PASSWORD` before `DATABASE_URL` and `REDIS_PASSWORD` before `REDIS_URL` in all workloads so that shell expansion with `$(...)` works reliably.

## Migrations

By default, this chart uses a **Helm hook Job** to prepare the database on **post-install/upgrade** using Rails' `db:prepare`, which will create the database (if needed) and apply migrations in one step. The Job waits for the database to be reachable via `pg_isready` before connecting.

Execution flow:

1. CNPG Cluster (if enabled) and other resources are created.
2. `sure-migrate` Job (post-install/post-upgrade hook) waits for the RW service to accept connections.
3. `db:prepare` runs; safe and idempotent across fresh installs and upgrades.
4. Optional data backfills (like SimpleFin encryption) run in their own post hooks.

To use the initContainer strategy instead (or in addition as a safety net):

```yaml
migrations:
  strategy: initContainer
  initContainer:
    enabled: true
```

## SimpleFin encryption backfill

- SimpleFin encryption is optional. If you enable it, you must provide Active Record Encryption keys.
- The backfill Job runs a safe, idempotent Rake task to encrypt existing `access_url` values.

```yaml
simplefin:
  encryption:
    enabled: true
    backfill:
      enabled: true
      dryRun: true  # set false to actually write changes

rails:
  # Provide encryption keys via an existing secret or below values (for testing only)
  existingSecret: my-app-secret
  # or
  secret:
    enabled: true
    values:
      ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY: "..."
      ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY: "..."
      ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT: "..."
```

## Ingress

```yaml
ingress:
  enabled: true
  className: "nginx"
  hosts:
    - host: finance.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - hosts: [finance.example.com]
      secretName: finance-tls
```

## Boot-required secrets

The Rails initializer for Active Record Encryption loads on boot. To prevent boot crashes, ensure the following environment variables are present for ALL workloads (web, worker, migrate job/initContainer, CronJobs, and the SimpleFin backfill job):

- `SECRET_KEY_BASE`
- `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`
- `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY`
- `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT`

This chart wires these from your app Secret using `secretKeyRef`. Provide them via `rails.existingSecret` (recommended) or `rails.secret.values` (for testing only).

The injection of the three Active Record Encryption env vars can be toggled via:

```yaml
rails:
  encryptionEnv:
    enabled: true  # set to false to skip injecting the three AR encryption env vars
```

Note: In self-hosted mode, if these env vars are not provided, they will be automatically generated from `SECRET_KEY_BASE`. In managed mode, these env vars must be explicitly provided via environment variables or Rails credentials.

## Advanced environment variable injection

For simple string key/value envs, continue to use `rails.extraEnv` and the per-workload `web.extraEnv` / `worker.extraEnv` maps.

When you need `valueFrom` (e.g., Secret/ConfigMap references) or full EnvVar objects, use the new arrays:

```yaml
rails:
  extraEnvVars:
    - name: SOME_FROM_SECRET
      valueFrom:
        secretKeyRef:
          name: my-secret
          key: some-key
  extraEnvFrom:
    - secretRef:
        name: another-secret
```

These are injected into web, worker, migrate job/initContainer, CronJobs, and the SimpleFin backfill job in addition to the simple maps.

## Writable filesystem and /tmp

Rails and Sidekiq may require writes to `/tmp` during boot. The chart now defaults to:

```yaml
securityContext:
  readOnlyRootFilesystem: false
```

If you choose to enforce a read-only root filesystem, you can mount an ephemeral `/tmp` via:

```yaml
writableTmp:
  enabled: true
```

This will add an `emptyDir` volume mounted at `/tmp` for the web and worker pods.

## Local images on k3s/k3d/kind (development workflow)

When using locally built images on single-node k3s/k3d/kind clusters:

- Consider forcing a never-pull policy during development:
  ```yaml
  image:
    pullPolicy: Never
  ```
- Load your local image into the cluster runtime:
  - k3s (containerd):
    ```bash
    # Export your image to a tar (e.g., from Docker or podman)
    docker save ghcr.io/we-promise/sure:dev -o sure-dev.tar
    # Import into each node's containerd
    sudo ctr -n k8s.io images import sure-dev.tar
    ```
  - k3d:
    ```bash
    k3d image import ghcr.io/we-promise/sure:dev -c <your-cluster-name>
    ```
  - kind:
    ```bash
    kind load docker-image ghcr.io/we-promise/sure:dev --name <your-cluster-name>
    ```
- Multi-node clusters require loading the image into every node or pushing to a registry that all nodes can reach.

## HPAs

```yaml
hpa:
  web:
    enabled: true
    minReplicas: 2
    maxReplicas: 10
    targetCPUUtilizationPercentage: 70

  worker:
    enabled: true
    minReplicas: 2
    maxReplicas: 10
    targetCPUUtilizationPercentage: 70
```

## Security Notes

- Never commit secrets in `values.yaml`. Use `rails.existingSecret` or a tool like Sealed Secrets.
- The chart defaults to `runAsNonRoot`, `fsGroup=1000`, and drops all capabilities.
- For production, set resource requests/limits and enable HPAs.

## Values overview

Tip: For production stability, prefer immutable image tags. Set `image.tag` to a specific release (e.g., `v1.2.3`) rather than `latest`.

See `values.yaml` for the complete configuration surface, including:

- `image.*`: repository, tag, pullPolicy, imagePullSecrets
- `rails.*`: environment, extraEnv, existingSecret or secret.values, settings
  - Also: `rails.extraEnvVars[]` (full EnvVar), `rails.extraEnvFrom[]` (EnvFromSource), and `rails.encryptionEnv.enabled` toggle
- `cnpg.*`: enable operator subchart and a Cluster resource, set instances, storage
- `redis-ha.*`: enable dandydev/redis-ha subchart and configure replicas/auth (Sentinel/HA); supports `existingSecret` and `existingSecretPasswordKey`
- `redisOperator.*`: optionally install OT redis-operator (`redisOperator.enabled`) and/or render a `RedisSentinel` CR (`redisOperator.managed.enabled`); configure `name`, `replicas`, `auth.existingSecret/passwordKey`, `persistence.className/size`, scheduling knobs, and `operator.resources` (controller) / `workloadResources` (Redis pods)
- `redisSimple.*`: optional single‑pod Redis (non‑HA) when `redis-ha.enabled=false`
- `web.*`, `worker.*`: replicas, probes, resources, scheduling, **strategy** (rolling update configuration)
- `migrations.*`: strategy job or initContainer
- `simplefin.encryption.*`: enable + backfill options
- `cronjobs.*`: custom CronJobs
- `service.*`, `ingress.*`, `serviceMonitor.*`, `hpa.*`

## Helm tests

After installation, you can run chart tests to verify:

- The web Service responds over HTTP.
- Redis auth works when an in-cluster provider is active.

```sh
helm test sure -n sure
```

The Redis auth test uses `redis-cli -u "$REDIS_URL" -a "$REDIS_PASSWORD" PING` and passes when `PONG` is returned.

Alternatively, you can smoke test from a running worker pod:

```sh
kubectl exec -n sure deploy/$(kubectl get deploy -n sure -o name | grep worker | cut -d/ -f2) -- \
  sh -lc 'redis-cli -u "$REDIS_URL" -a "$REDIS_PASSWORD" PING'
```

## Testing locally (k3d/kind)

- Create a cluster (ensure storageclass is available).
- Install chart with defaults (CNPG + Redis included).
- Wait for CNPG Cluster to become Ready, then for Rails web and worker pods to be Ready.
- Port-forward or configure Ingress.

```sh
helm template sure charts/sure -n sure --debug > rendered.yaml  # dry-run inspection
helm upgrade --install sure charts/sure -n sure --create-namespace --wait
kubectl get pods -n sure
```

## Uninstall

```sh
helm uninstall sure -n sure
```

## Cleanup & reset (k3s)

For local k3s experimentation it's sometimes useful to completely reset the `sure` namespace, especially if CR finalizers or PVCs get stuck.

The script below is a **last-resort tool** for cleaning the namespace. It:

- Uninstalls the Helm release.
- Deletes RedisReplication and CNPG Cluster CRs in the namespace.
- Deletes PVCs.
- Optionally clears finalizers on remaining CRs/PVCs.
- Deletes the namespace.

> ⚠️ Finalizer patching can leave underlying volumes behind if your storage class uses its own finalizers (e.g. Longhorn snapshots). Use with care in production.

```bash
#!/usr/bin/env bash
set -euo pipefail

NAMESPACE=${NAMESPACE:-sure}
RELEASE=${RELEASE:-sure}

echo "[sure-cleanup] Cleaning up Helm release '$RELEASE' in namespace '$NAMESPACE'..."

helm uninstall "$RELEASE" -n "$NAMESPACE" || echo "[sure-cleanup] Helm release not found or already removed."

# 1) Patch finalizers FIRST so deletes don't hang
if kubectl get redisreplication.redis.redis.opstreelabs.in -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "[sure-cleanup] Clearing finalizers from RedisReplication CRs..."
  for rr in $(kubectl get redisreplication.redis.redis.opstreelabs.in -n "$NAMESPACE" -o name); do
    kubectl patch "$rr" -n "$NAMESPACE" -p '{"metadata":{"finalizers":null}}' --type=merge || true
  done
fi

if kubectl get redissentinels.redis.redis.opstreelabs.in -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "[sure-cleanup] Clearing finalizers from RedisSentinel CRs..."
  for rs in $(kubectl get redissentinels.redis.redis.opstreelabs.in -n "$NAMESPACE" -o name); do
    kubectl patch "$rs" -n "$NAMESPACE" -p '{"metadata":{"finalizers":null}}' --type=merge || true
  done
fi

if kubectl get pvc -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "[sure-cleanup] Clearing finalizers from PVCs..."
  for pvc in $(kubectl get pvc -n "$NAMESPACE" -o name); do
    kubectl patch "$pvc" -n "$NAMESPACE" -p '{"metadata":{"finalizers":null}}' --type=merge || true
  done
fi

# 2) Now delete CRs/PVCs without waiting
if kubectl get redisreplication.redis.redis.opstreelabs.in -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "[sure-cleanup] Deleting RedisReplication CRs (no wait)..."
  kubectl delete redisreplication.redis.redis.opstreelabs.in -n "$NAMESPACE" --all --wait=false || true
fi

if kubectl get redissentinels.redis.redis.opstreelabs.in -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "[sure-cleanup] Deleting RedisSentinel CRs (no wait)..."
  kubectl delete redissentinels.redis.redis.opstreelabs.in -n "$NAMESPACE" --all --wait=false || true
fi

if kubectl get cluster.postgresql.cnpg.io -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "[sure-cleanup] Deleting CNPG Cluster CRs (no wait)..."
  kubectl delete cluster.postgresql.cnpg.io -n "$NAMESPACE" --all --wait=false || true
fi

if kubectl get pvc -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "[sure-cleanup] Deleting PVCs in namespace $NAMESPACE (no wait)..."
  kubectl delete pvc -n "$NAMESPACE" --all --wait=false || true
fi

# 3) Delete namespace
if kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
  echo "[sure-cleanup] Deleting namespace $NAMESPACE..."
  kubectl delete ns "$NAMESPACE" --wait=false || true
else
  echo "[sure-cleanup] Namespace $NAMESPACE already gone."
fi

echo "[sure-cleanup] Done."
```
