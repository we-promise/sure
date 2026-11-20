# API endpoint consistency (post-commit checklist)

When adding or modifying API v1 endpoints, follow this checklist after every API endpoint commit so behavior, docs, and auth stay consistent. Runtime endpoints also support OAuth; the API-key-only requirement below applies to the behavioral test and documentation patterns.

## 1. Minitest behavioral coverage

- **Location**: `test/controllers/api/v1/{resource}_controller_test.rb`
- **Scope**: All new or changed actions must have Minitest coverage here. Do not rely on rswag specs for behavioral assertions.
- **Pattern**:
  - Use `ApiKey.create!` (read and read_write scopes) and `api_headers(api_key)` → `{ "X-Api-Key" => api_key.display_key }`. Do not use OAuth/Bearer in these tests.
  - Cover: index/show (and create/update/destroy for write endpoints), read-only key blocking writes (403), invalid params (422), invalid date (422), not found (404), missing auth (401).
  - Follow existing API v1 test style: see [valuations_controller_test.rb](../../test/controllers/api/v1/valuations_controller_test.rb) and [transactions_controller_test.rb](../../test/controllers/api/v1/transactions_controller_test.rb).

## 2. rswag is docs-only

- **Location**: `spec/requests/api/v1/{resource}_spec.rb`
- **Rule**: These specs exist only for OpenAPI generation. Do not add `expect(...)` or `assert_*` (or any behavioral assertions). Use `run_test!` without custom assertion blocks so the spec only documents request/response and regenerates `docs/api/openapi.yaml`.
- **Regenerate**: After edits, run `RAILS_ENV=test bundle exec rake rswag:specs:swaggerize`.

## 3. Same API key auth in all rswag specs

- **Rule**: Every request spec in `spec/requests/api/v1/` must use the same API key auth pattern so generated docs are consistent.
- **Pattern** (match holdings_spec, trades_spec, transactions_spec, etc.):

  ```ruby
  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'API Docs Key',
      key: key,
      scopes: %w[read_write],
      source: 'web'
    )
  end

  let(:'X-Api-Key') { api_key.plain_key }
  ```

- Do not use Doorkeeper/OAuth in these specs (no `Doorkeeper::Application`, `Doorkeeper::AccessToken`, or `Authorization: "Bearer ..."`). Use API key only.

## OpenAPI schemas and verification

Adding or modifying an API endpoint requires corresponding documentation specs.
Define reusable schemas in [`spec/swagger_helper.rb`](../../spec/swagger_helper.rb).
Generated documentation lives in [`docs/api/openapi.yaml`](../api/openapi.yaml).

Verify the guidance without booting Rails:

```sh
ruby test/support/verify_api_endpoint_consistency.rb
ruby test/support/verify_api_endpoint_consistency.rb --compliance
```

The second command reports existing API compliance issues; its inventory is not a
replacement for running the behavioral tests or regenerating OpenAPI documentation.
