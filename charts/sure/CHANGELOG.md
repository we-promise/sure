### 0.0.0

- First (nightly/test) releases via https://we-promise.github.io/sure/index.yaml

### 0.6.5

- First version/release that aligns versions with monorepo
- CNPG: render `Cluster.spec.backup` from `cnpg.cluster.backup`.
  - If `backup.method` is omitted and `backup.volumeSnapshot` is present, the chart will infer `method: volumeSnapshot`.
  - For snapshot backups, `backup.volumeSnapshot.className` is required (template fails early if missing).
  - Example-only keys like `backup.ttl` and `backup.volumeSnapshot.enabled` are stripped to avoid CRD warnings.
- CNPG: render `Cluster.spec.plugins` from `cnpg.cluster.plugins` (enables barman-cloud plugin / WAL archiver configuration).
