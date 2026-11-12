# Encryption key rotation (self-hosted)

If your `SECRET_KEY_BASE` was ever shipped as a default in this project's
example Compose files (the boot log warns about this explicitly), or your
Active Record Encryption keys leaked for any other reason, the keys must be
rotated. Rotation is **not** just "set new keys and run the backfill": data
already encrypted under the old key must stay readable while it migrates,
and one class of columns — the deterministic ones — needs an explicit extra
step. This page is the full procedure the boot warning summarizes.

> Automated rotation tooling (one task covering everything below) is tracked
> in [we-promise/sure#3233](https://github.com/we-promise/sure/issues/3233).
> Until it lands, follow the manual steps.

Take a database backup before starting, and expect a short maintenance
window for step 3–4.

## 1. Configure the new keys alongside the compromised ones

Generate a fresh key set:

```sh
bin/rails db:encryption:init
```

Set the new values as the current keys (via
`ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`,
`ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY` and
`ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT`), and keep the compromised
set decryptable as a `previous` scheme — see the
[Rails key-rotation guide](https://guides.rubyonrails.org/active_record_encryption.html#key-rotation).
For example, in a temporary initializer that runs after the app's own
encryption initializer:

```ruby
# config/initializers/zz_encryption_rotation.rb  (TEMPORARY - deleted in step 4)
Rails.application.config.active_record.encryption.previous_schemes <<
  ActiveRecord::Encryption::Scheme.new(
    primary_key: ENV.fetch("OLD_ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"),
    deterministic_key: ENV.fetch("OLD_ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"),
    key_derivation_salt: ENV.fetch("OLD_ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT")
  )
```

Restart the app. Reads of old ciphertext keep working (Rails tries previous
schemes when decrypting), and new writes of ordinary encrypted attributes
use the new key.

## 2. Backfill — plaintext and ordinary encrypted columns

```sh
bin/rails security:backfill_encryption                    # dry run: reports what would change
DRY_RUN=false bin/rails security:backfill_encryption      # actually re-encrypts
```

The task defaults to a dry run that changes nothing, so the plain command is
a safe preview. The write pass migrates never-encrypted legacy rows and
re-encrypts non-deterministic columns (e.g. `first_name`, `last_name`,
provider `raw_payload`s) under the new key.

**It does not migrate deterministic columns** — see the next step.

## 3. Migrate the deterministic attributes explicitly

Rails treats deterministic attributes (`encrypts ..., deterministic: true`
— user emails, `otp_secret`, invitation/invite tokens, provider tokens) as
*fixed*: while any previous scheme is configured, it deliberately
re-serializes them under the **oldest** scheme so that equality lookups
produce stable ciphertext
([`EncryptedAttributeType#serialize_with_oldest`](https://github.com/rails/rails/blob/main/activerecord/lib/active_record/encryption/encrypted_attribute_type.rb)).
Consequence: the step-2 backfill rewrites those columns right back under
the compromised key. They must be re-encrypted under the current key with
an explicit pass **before** the compromised scheme is retired.

List every affected attribute:

```sh
grep -rn "deterministic: true" app/models
```

Then, for each model/attribute, decrypt-and-rewrite through a type that
knows only the current scheme. Example for `User#email` (mirror each
attribute's own declaration options — here `downcase: true`):

```ruby
# bin/rails runner rotate_deterministic.rb
new_key_type = ActiveRecord::Encryption::EncryptedAttributeType.new(
  scheme: ActiveRecord::Encryption::Scheme.new(deterministic: true, downcase: true),
  cast_type: ActiveRecord::Type::Text.new
)

User.find_each do |user|
  plain = user.email                    # decrypts under whichever scheme can read it
  next if plain.blank?
  user.update_columns(email: new_key_type.serialize(plain))
end
```

Notes:

- `update_columns` is intentional: it bypasses callbacks/validations and
  writes the exact ciphertext produced above.
- Run this while **both** schemes are still configured. Lookups keep
  matching throughout: `extend_queries` (enabled by this app) extends
  deterministic queries to every configured scheme, so rows on the old key
  and rows on the new key are both found during the mixed window.
- Repeat for every attribute from the grep, adjusting `deterministic:` /
  `downcase:` / `ignore_case:` to match its `encrypts` declaration.

### Verify before retiring the old key

A ciphertext that still needs the compromised key must not survive this
step. Check every rewritten column decrypts under the **new scheme only**
(`support_unencrypted_data: false` is what makes this check strict — the
app's global setting would otherwise paper over failures by returning the
raw ciphertext):

```ruby
strict_type = ActiveRecord::Encryption::EncryptedAttributeType.new(
  scheme: ActiveRecord::Encryption::Scheme.new(
    deterministic: true, downcase: true, support_unencrypted_data: false
  ),
  cast_type: ActiveRecord::Type::Text.new
)

bad = 0
User.find_each do |user|
  raw = user.read_attribute_before_type_cast(:email)
  next if raw.blank?
  begin
    strict_type.deserialize(raw)
  rescue ActiveRecord::Encryption::Errors::Decryption
    bad += 1
  end
end
puts "rows not yet on the new key: #{bad}"
```

`bad` must be 0 for every deterministic column before moving on. (Legacy
rows that were never encrypted at all also fail this check — run the
step-2 backfill first, or re-run step 3 for those rows.)

## 4. Retire the compromised scheme

Only after step 3's verification passes for every deterministic attribute:
delete `config/initializers/zz_encryption_rotation.rb` (and the
`OLD_ACTIVE_RECORD_ENCRYPTION_*` variables), restart, and spot-check a
login, a deterministic lookup (`User.find_by(email:)`), a provider sync and
an MFA flow.

## What this does not cover

- **`SECRET_KEY_BASE` itself** still signs session cookies and is the sole
  key source for `Setting`-encrypted values (AI/market-data provider keys).
  Rotating it invalidates existing sessions and Setting-stored values,
  which must be re-entered — there is no automated migration for those two.
- Rotating `SECRET_KEY_BASE` also changes the auto-derived AR encryption
  keys on installs that never set them explicitly; that is exactly the
  scenario this procedure exists for.
