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

    # holdings.source was added by AddSourceToHoldings (20260504140000); refresh
    # column cache so the application Holding model in this process picks it up.
    Holding.reset_column_information

    items = LegacyPlaidItem.find_each.to_a
    say_with_time "Migrating #{items.size} PlaidItem(s) to Provider::Connection" do
      items.each { |item| migrate_item(item) }
    end
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
            # Discriminator used by MigrationNotice (e.g. plaid_oauth_redirect_uri):
            # only legacy-migrated connections need the operator to update their
            # Plaid Dashboard. Connections created via the new EmbeddedLink flow
            # already use the framework redirect URI from day one.
            "migrated_from_legacy"    => true,
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

        # Stale legacy AccountProvider rows of provider_type='PlaidAccount':
        #   - their polymorphic provider_id targets a PlaidAccount that's about to be dropped,
        #   - their account_id linkage is replaced by Provider::Account.account_id.
        # Two steps in this order:
        #   1. Backfill holdings.source = "plaid" so the new from_provider scope still
        #      identifies these holdings as provider snapshots after we nullify their
        #      account_provider_id. (Source identification is otherwise lost — the
        #      framework's Plaid::Investments::HoldingsProcessor writes source, but
        #      pre-cutover holdings only had account_provider_id.)
        #   2. AccountProvider.destroy_all (rather than raw DELETE) so dependent: :nullify
        #      on the holdings association fires — without this, the FK
        #      `add_foreign_key "holdings", "account_providers"` (no ON DELETE) would
        #      raise PG::ForeignKeyViolation on Plaid investment users.
        # Both happen inside the per-item transaction so a partial failure rolls back
        # cleanly and the whole task is idempotent on re-run.
        legacy_account_ids = legacy_accounts.pluck(:id)
        stale_ap_ids = AccountProvider.where(provider_type: "PlaidAccount", provider_id: legacy_account_ids).pluck(:id)
        if stale_ap_ids.any?
          backfilled = Holding.where(account_provider_id: stale_ap_ids, source: nil).update_all(source: "plaid")
          AccountProvider.where(id: stale_ap_ids).destroy_all
          say "  + Backfilled source on #{backfilled} holding(s); removed #{stale_ap_ids.size} stale AccountProvider row(s)", true
        end

        say "  + Migrated PlaidItem #{item.id} → Provider::Connection #{connection.id} (#{legacy_accounts.size} account(s))", true
      end

      # Re-point Plaid's webhook URL outside the DB transaction. Plaid stores the
      # URL on its side; until we tell it otherwise it keeps POSTing to the legacy
      # /webhooks/plaid[_eu] routes — which were dropped in the framework cutover.
      # Best-effort: a Plaid API failure here only logs (the data move already
      # committed). Operator can re-run data_migration:migrate_plaid_webhooks for
      # any items that didn't get re-pointed cleanly.
      repoint_webhook(item)
    rescue => e
      say "  ! Failed to migrate PlaidItem #{item.id}: #{e.class}: #{e.message}", true
      raise
    end

    def repoint_webhook(item)
      host = ENV["APP_DOMAIN"].presence
      unless host
        say "  ~ APP_DOMAIN not set; skipping webhook re-point for item #{item.id} (run data_migration:migrate_plaid_webhooks once it is)", true
        return
      end
      host = "https://#{host}" unless host.match?(%r{\Ahttps?://})

      region = item.plaid_region.presence || "us"
      provider = Provider::Registry.plaid_provider_for_region(region.to_sym)
      unless provider
        say "  ~ No Plaid provider configured for region=#{region}; skipping webhook re-point for item #{item.id}", true
        return
      end

      provider.client.item_webhook_update(
        Plaid::ItemWebhookUpdateRequest.new(
          access_token: item.access_token,
          webhook: "#{host.chomp('/')}/webhooks/providers/plaid"
        )
      )
      say "  + Re-pointed Plaid webhook for item #{item.id} (region=#{region})", true
    rescue => e
      say "  ! Could not re-point Plaid webhook for item #{item.id}: #{e.class}: #{e.message}", true
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
