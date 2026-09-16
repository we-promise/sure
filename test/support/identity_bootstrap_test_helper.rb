require_relative "provider_ingestion_test_helper"

module IdentityBootstrapTestHelper
  include ProviderIngestionTestHelper

  Context = Data.define(:family, :item, :source, :account, :link, :copier, :control, :mapping, :external) do
    def inspect
      "#<#{self.class.name}>"
    end
  end

  def with_identity_source(**options, &block)
    if options.fetch(:provider_key, "up") == "plaid"
      with_identity_plaid_application { with_identity_source_records(**options, &block) }
    else
      with_identity_source_records(**options, &block)
    end
  end

  def with_identity_source_records(provider_key: "up", quiesced: true, plaid_transactions: [])
    with_provider_encryption do
      family = families(:dylan_family)
      item = case provider_key
      when "up"
        UpItem.create!(family: family, name: "Bootstrap publisher", access_token: "private-bootstrap-token")
      when "plaid"
        PlaidItem.create!(family: family, name: "Bootstrap publisher", access_token: "private-bootstrap-token",
          plaid_id: SecureRandom.uuid, plaid_region: "eu")
      else
        raise ArgumentError, "Unsupported bootstrap test fixture"
      end
      account = family.accounts.create!(name: "Retained financial account", currency: "USD", balance: BigDecimal("1234.5678"),
        accountable: Depository.new, status: "active")
      begin
        source = if provider_key == "up"
          item.up_accounts.create!(account_id: SecureRandom.uuid, name: "Checking", currency: "USD", current_balance: BigDecimal("1234.5678"), raw_transactions_payload: [])
        else
          item.plaid_accounts.create!(plaid_id: SecureRandom.uuid, name: "Checking", currency: "USD", plaid_type: "depository", current_balance: BigDecimal("1234.5678")).tap do |created|
            created.update!(raw_transactions_payload: { "added" => plaid_transactions.map { |row| row.stringify_keys.merge("account_id" => created.plaid_id) } })
          end
        end
        link = AccountProvider.create!(account: account, provider: source)
        copier = Provider::AccountData::MigrationCopier.new(provider_key: provider_key, legacy_item_id: item.id, batch_size: 1)
        control = nil
        15.times do
          control = (quiesced ? copier.run_quiesced : copier.run).reload
          break if quiesced ? control.high_water_mark["phase"] == "verified" : control.shadow?
        end
        assert(quiesced ? control.quiescing? : control.shadow?)
        assert_equal "verified", control.high_water_mark["phase"] if quiesced
        external = control.provider_connection.external_accounts.sole
        mapping = control.provider_migration_mappings.find_by!(role: "external_account", external_account: external)
        Account::SourcePolicy.select!(account: account, account_provider: link.reload, resource: "transactions")
        yield Context.new(family: family, item: item, source: source, account: account, link: link.reload,
          copier: copier, control: control, mapping: mapping, external: external)
      ensure
        cleanup_identity_source(item, account)
      end
    end
  end

  def identity_entry(context, external_id:, source: context.control.provider_key, extra: {}, **attributes)
    context.account.entries.create!({ name: "Original financial description", date: Date.current, amount: BigDecimal("12.3456"),
      currency: "USD", source: source, external_id: external_id, entryable: Transaction.new(extra: extra) }.merge(attributes))
  end

  def identity_financial_snapshot(context)
    { "account" => context.account.reload.attributes,
      "entries" => context.account.entries.order(:id).map { |entry| [ entry.attributes, entry.entryable.attributes ] } }
  end

  def assert_no_financial_sql(queries)
    writes = queries.grep(/\A(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+"?(?:entries|transactions|trades|accounts)"?\b/i)
    assert_empty writes, "Identity publication must not write financial tables"
  end

  private
    def with_identity_plaid_application
      values = { "plaid_eu_client_id" => "identity-eu-client", "plaid_eu_secret" => "identity-eu-secret", "plaid_eu_environment" => "production" }
      previous = values.keys.to_h do |key|
        record = Setting.unscoped.find_by(var: "dynamic:#{key}")
        [ key, record && { record: record, value: record.value, updated_at: record.updated_at } ]
      end
      configuration = Rails.application.config.plaid_eu
      values.each { |key, value| Setting[key] = value }
      Rails.application.config.plaid_eu = nil
      yield
    ensure
      if previous
        previous.each do |key, retained|
          if retained
            Setting[key] = retained.fetch(:value)
            retained.fetch(:record).update_column(:updated_at, retained.fetch(:updated_at))
          else
            Setting.unscoped.where(var: "dynamic:#{key}").destroy_all
          end
        end
        Setting.clear_cache
        Rails.application.config.plaid_eu = configuration
      end
    end

    def cleanup_identity_source(item, account)
      manifest = Provider::AccountData::MigrationManifest.all.find { |candidate| candidate.item_type == item.class.name }
      control = ProviderMigrationControl.find_by(legacy_type: item.class.name, legacy_id: item.id)
      connection = control&.provider_connection
      if connection
        ProviderMigrationAccountBinding.where(provider_migration_mapping_id: control.provider_migration_mappings.select(:id)).delete_all
        observations = SourceRecord.where(external_account_id: connection.external_accounts.select(:id))
        EntrySource.where(source_record_id: observations.select(:id)).delete_all
        observations.delete_all
        connection.provider_sync_checkpoints.delete_all
        connection.ingestion_batches.delete_all
      end
      Account::SourcePolicy.where(account_id: account.id).delete_all
      AccountProvider.where(account_id: account.id).delete_all
      control&.provider_migration_mappings&.delete_all
      control&.delete
      connection&.destroy!
      account.reload.destroy!
      manifest.account_type.constantize.where(manifest.account_foreign_key => item.id).delete_all
      item.delete # Do not invoke remote Plaid item-removal callbacks during cleanup.
    end
end
