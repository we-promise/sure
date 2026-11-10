# Provider-secret review notes

Personal review notes for discussion; not settled implementation decisions.

## Revisit the factory's `strict:` flag

The draft adds `strict: false` to `Provider::Factory.ensure_adapters_loaded`.
Existing callers log and skip adapter loading errors; secret metadata lookup
passes `strict: true` to raise instead.

Review concern: a caller-specific boolean changes a shared method's failure
contract. This may hide a loading/design issue and make future callers harder to
reason about. Do not assume this is the right abstraction merely because it makes
the tests pass.

- Why does the existing loader tolerate adapter loading failures?
- Does secret-field discovery belong in that loader at all?
- Is there an established initialization or registry-completeness guarantee we
  should use instead?
- Can we avoid the behavioral flag while still preventing incomplete metadata
  from allowing plaintext writes?
- Discuss with the maintainer before accepting this change.

## Consider keeping the YAML value a string

Each dynamic setting already has its own row. The row's `var` remains
`dynamic:plaid_secret`; the examples below show the entire `value` column using
fabricated data.

Existing format:

```yaml
--- synthetic-plaid-secret
```

Current draft changes the YAML document from a string to a mapping:

```yaml
---
sure_provider_secret: 1
ciphertext: <encrypted-content>
```

Alternative to discuss: keep a YAML string, with an identifying prefix and version:

```yaml
--- sure-secret:v1:<encrypted-content>
```

- Could the prefixed string make this a smaller, easier-to-review format change?
- Either format needs strict recognition: marked ciphertext that fails decryption
  should not be mistaken for legacy plaintext.
- Bare ciphertext would leave ambiguity between legacy plaintext, corruption and
  a wrong encryption key unless a mandatory conversion removes legacy support.
- Neither encrypted format is compatible with old releases: they would treat the
  stored encrypted value as the actual provider credential.
- Confirm the preferred format and conversion strategy with the maintainer before
  changing the draft.
