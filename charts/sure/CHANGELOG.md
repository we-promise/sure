### 0.0.0

- First (nightly/test) releases via <https://we-promise.github.io/sure/index.yaml>

### 0.6.5

- First version/release that aligns versions with monorepo
- CNPG: render `Cluster.spec.backup` from `cnpg.cluster.backup`.
  - If `backup.method` is omitted and `backup.volumeSnapshot` is present, the chart will infer `method: volumeSnapshot`.
  - For snapshot backups, `backup.volumeSnapshot.className` is required (template fails early if missing).
  - Example-only keys like `backup.ttl` and `backup.volumeSnapshot.enabled` are stripped to avoid CRD warnings.
- CNPG: render `Cluster.spec.plugins` from `cnpg.cluster.plugins` (enables barman-cloud plugin / WAL archiver configuration).

### 0.6.6

- Made Kubernetes rolling update strategy configurable for web and worker deployments. Changed defaults from `maxUnavailable=0`/`maxSurge=25%` to `maxUnavailable=1`/`maxSurge=0` to prevent deployment deadlocks when using topology spread constraints with `DoNotSchedule`.
- Security: Updated uri gem from 1.0.3 to 1.0.4 to address CVE-2025-61594.
- Security: Updated httparty gem from 0.23.1 to 0.24.0, including security fix for SSRF vulnerability (GHSA-hm5p-x4rq-38w4), performance improvements for file uploads, and bug fixes for encoding and content-type handling.