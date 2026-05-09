# Migrates legacy plaid_items + plaid_accounts data into the new
# Provider::Connection + Provider::Account framework, between the schema
# migration that adds raw_transactions_payload (20260504100000) and the
# table-drop (20260504200000). Idempotent — if a Provider::Connection with
# the matching plaid_item_id metadata already exists, the row is skipped.
#
# Inline LegacyPlaidItem / LegacyPlaidAccount stubs are used because the
# real PlaidItem/PlaidAccount model classes have been deleted from the
# codebase. The tables themselves still exist at this point in the migration
# timeline.
class MigrateLegacyPlaidToFramework < ActiveRecord::Migration[7.2]
  # PlaidItem.status uses the legacy enum values; Provider::Connection.status
  # uses the new ones. Mapping is explicit so any unrecognised legacy value
  # raises rather than silently writing through.
  STATUS_MAP = { "good" => "healthy", "requires_update" => "requires_update" }.freeze

  # Mirror the original PlaidItem/PlaidAccount encryption_ready? logic. Original
  # models conditionally apply `encrypts` based on credentials/env presence —
  # the migration must read columns the same way they were written. Checking
  # ActiveRecord::Encryption.config.primary_key.present? alone is wrong: Rails
  # auto-derives a primary key from SECRET_KEY_BASE in some contexts even when
  # the original models considered themselves unconfigured and wrote plaintext.
  def self.encryption_ready?
    creds_ready = Rails.application.credentials.active_record_encryption.present?
    env_ready = ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"].present? &&
                ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"].present? &&
                ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"].present?
    creds_ready || env_ready
  end

  class LegacyPlaidItem < ApplicationRecord
    self.table_name = "plaid_items"
    if MigrateLegacyPlaidToFramework.encryption_ready?
      encrypts :access_token, deterministic: true
      encrypts :raw_payload
      encrypts :raw_institution_payload
    end
  end

  class LegacyPlaidAccount < ApplicationRecord
    self.table_name = "plaid_accounts"
    if MigrateLegacyPlaidToFramework.encryption_ready?
      encrypts :raw_payload
      encrypts :raw_transactions_payload
      encrypts :raw_holdings_payload, previous: { attribute: :raw_investments_payload }
      encrypts :raw_liabilities_payload
    end
  end

  def up
    return unless table_exists?(:plaid_items) && table_exists?(:plaid_accounts)

    items = LegacyPlaidItem.find_each.to_a
    say_with_time "Migrating #{items.size} PlaidItem(s) to Provider::Connection" do
      items.each { |item| migrate_item(item) }
    end

    # The legacy polymorphic AccountProvider rows of provider_type='PlaidAccount'
    # are now stale: their provider_id targets are about to be dropped with
    # plaid_accounts (next migration), and the new Provider::Account.account_id
    # linkage replaces them. Delete here so views don't try to instantiate
    # adapters against a dropped class.
    deleted = ActiveRecord::Base.connection.delete(
      "DELETE FROM account_providers WHERE provider_type = 'PlaidAccount'"
    )
    say "Removed #{deleted} stale PlaidAccount AccountProvider row(s)" if deleted.positive?
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "plaid_items / plaid_accounts data cannot be reconstructed. Restore from backup if rollback is required."
  end

  private

    def migrate_item(item)
      # Idempotency: skip if already migrated.
      existing = Provider::Connection.where("metadata->>'plaid_item_id' = ?", item.plaid_id).first
      if existing
        say "  - PlaidItem #{item.id} already migrated → Provider::Connection #{existing.id}", true
        return
      end

      ActiveRecord::Base.transaction do
        connection = Provider::Connection.create!(
          family_id:    item.family_id,
          provider_key: "plaid",
          auth_type:    "embedded_link",
          credentials:  { "access_token" => item.access_token },
          status:       STATUS_MAP.fetch(item.status) { raise "Unknown PlaidItem status: #{item.status.inspect}" },
          metadata: {
            "plaid_item_id"           => item.plaid_id,
            "region"                  => item.plaid_region,
            "next_cursor"             => item.next_cursor,
            "institution_id"          => item.institution_id,
            "institution_url"         => item.institution_url,
            "institution_color"       => item.institution_color,
            "institution_name"        => item.name,
            "available_products"      => item.available_products,
            "billed_products"         => item.billed_products,
            "raw_item_payload"        => item.raw_payload,
            "raw_institution_payload" => item.raw_institution_payload
          },
          sync_start_date: item.created_at.to_date
        )

        legacy_accounts = LegacyPlaidAccount.where(plaid_item_id: item.id)
        legacy_accounts.each do |pa|
          Provider::Account.create!(
            provider_connection_id:    connection.id,
            account_id:                resolve_account_id(pa),
            external_id:               pa.plaid_id,
            external_name:             pa.name,
            external_type:             pa.plaid_type,
            external_subtype:          pa.plaid_subtype,
            currency:                  pa.currency,
            raw_payload:               pa.raw_payload || {},
            raw_transactions_payload:  pa.raw_transactions_payload,
            raw_holdings_payload:      pa.raw_holdings_payload,
            raw_liabilities_payload:   pa.raw_liabilities_payload
          )
        end

        say "  + Migrated PlaidItem #{item.id} → Provider::Connection #{connection.id} (#{legacy_accounts.size} account(s))", true
      end
    rescue => e
      say "  ! Failed to migrate PlaidItem #{item.id}: #{e.class}: #{e.message}", true
      raise
    end

    # Plaid accounts may link to a Sure Account via two legacy paths.
    # Walk both: prefer polymorphic AccountProvider, fall back to direct FK.
    def resolve_account_id(legacy_plaid_account)
      ap = AccountProvider.find_by(provider_type: "PlaidAccount", provider_id: legacy_plaid_account.id)
      return ap.account_id if ap

      # accounts.plaid_account_id is removed in the next migration but still
      # exists here; query via raw SQL to avoid relying on a deleted attribute.
      row = ActiveRecord::Base.connection.select_one(
        ActiveRecord::Base.sanitize_sql_array(
          [ "SELECT id FROM accounts WHERE plaid_account_id = ?", legacy_plaid_account.id ]
        )
      )
      row && row["id"]
    end
end
