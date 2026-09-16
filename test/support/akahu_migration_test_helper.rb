require "stringio"
require_relative "identity_bootstrap_test_helper"

# Real copy/preparation/cutover fixtures. Readiness is deliberately a caller's
# test-only override; this helper never runs a provider request or claims fetch
# coverage when it terminalizes the initial native Sync.
module AkahuMigrationTestHelper
  include IdentityBootstrapTestHelper
  include ActiveJob::TestHelper

  AkahuMigrationContext = Data.define(:family, :item, :source, :account, :link, :copier,
    :control, :mapping, :external, :blob, :logo_bytes) do
    def connection = control.provider_connection
    def actor = account.owner
    def inspect = "#<#{self.class.name}>"
  end

  def akahu_migration_transaction(changes = {})
    { "_id" => "retirement-transaction", "_account" => "akahu-retained-remote", "amount" => "-12.34",
      "currency" => "NZD", "date" => "2020-01-02", "description" => "Original Akahu coffee", "type" => "DEBIT",
      "meta" => { "reference" => "Retained reference", "particulars" => "Retained particulars", "code" => "CODE" } }.merge(changes)
  end

  def with_akahu_migration_source(rows: nil, logo: false, cutover: true, process_account: false,
    item_attributes: {}, account_attributes: {}, source_attributes: {})
    with_provider_encryption do
      family = Family.create!(name: "Akahu migration test", timezone: "UTC")
      owner = family.users.create!(email: "akahu-migration-#{SecureRandom.uuid}@example.com",
        password: "akahu-migration-password", role: "admin")
      item = family.akahu_items.create!({ name: "Original Akahu", app_token: "private-akahu-retirement-app",
        user_token: "private-akahu-retirement-user" }.merge(item_attributes))
      account = family.accounts.create!({ owner: owner, name: "Original Akahu account", currency: "NZD",
        balance: 100, accountable: Depository.new, status: "active" }.merge(account_attributes))
      rows = [ akahu_migration_transaction ] if rows.nil?
      source = item.akahu_accounts.create!({ account_id: "akahu-retained-remote", name: "Checking", currency: "NZD",
        current_balance: 100, account_type: "CHECKING", account_status: "ACTIVE", raw_transactions_payload: rows }.merge(source_attributes))
      link = AccountProvider.create!(account: account, provider: source)
      if process_account
        AkahuAccount::Processor.new(source).process
      else
        rows.each { |row| AkahuEntry::Processor.new(row, akahu_account: source).process }
      end
      item.syncs.create!(status: "completed", completed_at: Time.current)
      blob = nil
      if logo
        logo_bytes = "\x89PNG\r\n\x1a\nretained-akahu-logo".b
        blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(logo_bytes), filename: "retained-akahu.png",
          content_type: "image/png", identify: false)
        item.logo.attach(blob)
      end
      copier = Provider::AccountData::MigrationCopier.new(provider_key: "akahu", legacy_item_id: item.id, batch_size: 1)
      control = nil
      20.times do
        control = copier.run_quiesced.reload
        break if control.high_water_mark["phase"] == "verified"
      end
      assert_equal "verified", control.high_water_mark["phase"]
      external = control.provider_connection.external_accounts.sole
      mapping = control.provider_migration_mappings.find_by!(role: "external_account", external_account: external)
      context = AkahuMigrationContext.new(family: family, item: item, source: source, account: account, link: link.reload,
        copier: copier, control: control, mapping: mapping, external: external, blob: blob, logo_bytes: logo_bytes)
      if cutover
        prepare_akahu_migration(context)
        initial = cutover_akahu_migration(context)
        initial.update!(status: "failed", completed_at: Time.current)
      end
      clear_enqueued_jobs
      yield context
    ensure
      if item && account
        connection = ProviderConnection.find_by(id: control&.provider_connection_id)
        ActiveStorage::Attachment.where(record_type: "ProviderConnection", record_id: connection.id).delete_all if connection
        ActiveStorage::Attachment.where(record_type: "AkahuItem", record_id: item.id).delete_all
        source_ids = AkahuAccount.where(akahu_item_id: item.id).pluck(:id)
        source_ids |= [ source.id ] if source
        ActiveStorage::Attachment.where(record_type: "AkahuAccount", record_id: source_ids).delete_all
        # Native financial batches reference their original Sync. The shared
        # cleanup removes those batches before connection.destroy! removes runs.
        Sync.where(syncable_type: "AkahuItem", syncable_id: item.id).destroy_all
        Sync.where(syncable_type: "AkahuAccount", syncable_id: source_ids).destroy_all
        cleanup_identity_source(item, account)
      end
      blob&.purge
      if family
        Session.where(user_id: family.users.select(:id)).delete_all
        family.users.each(&:destroy!)
      end
      family&.destroy!
      clear_enqueued_jobs
    end
  end

  def prepare_akahu_migration(context)
    150.times do
      result = Provider::AccountData::MigrationPreparation.new(provider_key: "akahu", legacy_item_id: context.item.id,
        family: context.family, page_size: 1).run
      return result if result.awaiting_acceptance?
    end
    flunk "Akahu preparation did not complete its bounded verification calls"
  end

  def cutover_akahu_migration(context)
    result = Provider::AccountData::MigrationCutover.new(provider_key: "akahu", legacy_item_id: context.item.id,
      family: context.family, page_size: 1).call
    context.control.reload
    context.link.reload
    context.external.reload
    Sync.find(result.sync_id)
  end
end
