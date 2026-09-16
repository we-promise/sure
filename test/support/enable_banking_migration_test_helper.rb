require_relative "identity_bootstrap_test_helper"

module EnableBankingMigrationTestHelper
  include IdentityBootstrapTestHelper
  include ActiveJob::TestHelper

  EnableBankingMigrationContext = Data.define(:family, :item, :source, :account, :link, :copier,
    :control, :mapping, :external) do
    def connection = control.provider_connection
    def actor = account.owner
    def inspect = "#<#{self.class.name}>"
  end

  def enable_banking_migration_transaction(changes = {})
    { "transaction_id" => "retained-transaction", "booking_date" => "2020-01-02",
      "transaction_amount" => { "amount" => "12.34", "currency" => "EUR" },
      "credit_debit_indicator" => "DBIT", "status" => "BOOK",
      "remittance_information" => [ "Retained reference" ], "note" => "Original note" }.merge(changes)
  end

  # The stable account identity deliberately differs from its API UUID. Every
  # receipt and authorization comes from the actual copier, never a fake map.
  # Readiness remains the caller's explicit test-only override.
  def with_enable_banking_migration_source(rows: [], linked: true, import: true, before_copy: nil,
    item_attributes: {}, source_attributes: {}, account_attributes: {})
    with_provider_encryption do
      family = Family.create!(name: "Enable Banking migration", timezone: "UTC")
      owner = family.users.create!(email: "enable-banking-migration-#{SecureRandom.uuid}@example.com",
        password: "enable-banking-migration-password", role: "admin")
      item = family.enable_banking_items.create!({ name: "Original Enable Banking", country_code: "FI",
        application_id: SecureRandom.uuid, client_certificate: "private-migration-certificate",
        authorization_id: nil, session_id: SecureRandom.uuid, session_expires_at: 1.month.from_now,
        aspsp_id: "fixture-institution", aspsp_name: "Fixture institution", psu_type: "personal",
        aspsp_psu_types: [ "personal" ], aspsp_required_psu_headers: [ "psu-ip-address" ], last_psu_ip: "192.0.2.1"
      }.merge(item_attributes))
      account = family.accounts.create!({ owner: owner, name: "Retained Enable Banking", currency: "EUR",
        balance: 100, accountable: Depository.new, status: "active" }.merge(account_attributes))
      source = item.enable_banking_accounts.create!({ uid: "stable-enable-banking-identity", account_id: SecureRandom.uuid,
        name: "Checking", currency: "EUR", current_balance: 100, account_type: "CACC",
        account_status: "ENABLED", identification_hashes: [ "stable-enable-banking-identity" ],
        raw_transactions_payload: rows }.merge(source_attributes))
      link = AccountProvider.create!(account: account, provider: source) if linked
      Array(rows).each { |row| EnableBankingEntry::Processor.new(row, enable_banking_account: source).process } if import && linked
      before_copy&.call(item, source, account)
      copier = Provider::AccountData::MigrationCopier.new(provider_key: "enable_banking", legacy_item_id: item.id, batch_size: 1)
      control = nil
      30.times do
        control = copier.run_quiesced.reload
        break if control.high_water_mark["phase"] == "verified"
      end
      assert_equal "verified", control.high_water_mark["phase"]
      external = control.provider_connection.external_accounts.sole
      mapping = control.provider_migration_mappings.find_by!(role: "external_account", external_account: external)
      Account::SourcePolicy.select!(account: account, account_provider: link.reload, resource: "transactions") if link
      yield EnableBankingMigrationContext.new(family: family, item: item, source: source, account: account, link: link,
        copier: copier, control: control, mapping: mapping, external: external)
    ensure
      if item && account
        source_ids = EnableBankingAccount.where(enable_banking_item_id: item.id).pluck(:id)
        Sync.where(syncable_type: "EnableBankingItem", syncable_id: item.id).delete_all
        Sync.where(syncable_type: "EnableBankingAccount", syncable_id: source_ids).delete_all
        cleanup_identity_source(item, account)
      end
      if family
        Session.where(user_id: family.users.select(:id)).delete_all
        family.users.each(&:destroy!)
      end
      family&.destroy!
      clear_enqueued_jobs
    end
  end

  def prepare_enable_banking_migration(context)
    150.times do
      result = Provider::AccountData::MigrationPreparation.new(provider_key: "enable_banking",
        legacy_item_id: context.item.id, family: context.family, page_size: 1).run
      return result if result.awaiting_acceptance?
    end
    flunk "Enable Banking preparation did not complete its bounded verification calls"
  end

  def cutover_enable_banking_migration(context)
    Provider::AccountData::MigrationCutover.new(provider_key: "enable_banking", legacy_item_id: context.item.id,
      family: context.family, page_size: 1).call
  end
end
