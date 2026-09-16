require "test_helper"
require_relative "../../support/provider_ingestion_test_helper"

class Ingestion::PendingTransactionMatchTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  include ActiveJob::TestHelper

  PROVIDERS = %w[akahu lunchflow redbark].freeze

  setup do
    PROVIDERS.each { |key| Provider::AccountData::Registry.declared_adapter(key).stubs(:native_ready?).returns(true) }
  end
  teardown { clear_enqueued_jobs }

  test "each opted-in provider settles onto the original UUID and retains the old source alias" do
    each_provider do |key, external, account|
      pending = record(key, pending: true)
      posted = record(key, pending: false)
      apply(external, pending)
      original = account.entries.sole
      original_mapping = original.entry_sources.sole

      assert_no_difference([ "Entry.count", "Transaction.count" ]) { apply(external, posted) }

      assert_equal original.id, account.entries.sole.id, key
      assert_equal posted[:external_id], original.reload.external_id, key
      assert_equal pending[:date], original.date, key
      assert_not original.transaction.pending?, key
      assert_equal [ pending[:external_id] ], original.transaction.extra.fetch("auto_claimed_pending_ids"), key
      retired = SourceRecord.find_by!(external_account: external, external_id: pending[:external_id])
      assert retired.withdrawn?, key
      assert_not retired.pending?, key
      assert_equal original_mapping.id, retired.entry_source.id, key
      assert_equal original.id, retired.entry_source.entry_identity, key
      current = SourceRecord.find_by!(external_account: external, external_id: posted[:external_id])
      assert_equal original.id, current.entry_source.entry_identity, key
      assert_equal "posting", current.entry_source.role, key
      assert_equal posted[:external_id], current.input_external_id, key
    end
  end

  test "replaying posted and retired pending observations cannot recreate or demote the entry" do
    each_provider do |key, external, account|
      pending, posted = record(key, pending: true), record(key, pending: false)
      apply(external, pending)
      apply(external, posted)
      entry = account.entries.sole
      entry.update!(user_modified: true, name: "My description", notes: "My note")
      expected = entry.attributes.slice("id", "external_id", "name", "notes", "amount", "currency", "date")
      sources = SourceRecord.where(external_account: external).order(:id).pluck(:id, :external_id, :withdrawn)

      assert_no_difference [ "Entry.count", "SourceRecord.count", "EntrySource.count" ] do
        apply(external, posted)
        apply(external, pending)
      end

      assert_equal expected, entry.reload.attributes.slice(*expected.keys), key
      assert_not entry.transaction.pending?, key
      assert_equal sources, SourceRecord.where(external_account: external).order(:id).pluck(:id, :external_id, :withdrawn), key
    end
  end

  test "pending and posted in one page use the same source-proven identity" do
    each_provider do |key, external, account|
      pending, posted = record(key, pending: true), record(key, pending: false)
      batch = apply(external, pending, posted)

      assert_equal 1, account.entries.count, key
      assert_equal posted[:external_id], account.entries.sole.external_id, key
      assert_equal 2, SourceRecord.where(external_account: external, ingestion_batch: batch).count, key
      assert_equal 1, EntrySource.where(account: account).distinct.count(:entry_identity), key
    end
  end

  test "protected and reconciled entries retain their financial fields under the explicit transition contract" do
    %i[user_modified import_locked excluded reconciled].each do |protection|
      each_provider do |key, external, account|
        pending, posted = record(key, pending: true), record(key, pending: false)
        apply(external, pending)
        entry = account.entries.sole
        changes = { name: "User description", notes: "User note" }
        changes[protection == :reconciled ? :reconciled_at : protection] = protection == :reconciled ? Time.current : true
        entry.update!(changes)
        before = entry.attributes.except("external_id", "source", "updated_at", "lock_version")

        assert_no_difference("Entry.count") { apply(external, posted) }

        assert_equal before, entry.reload.attributes.except("external_id", "source", "updated_at", "lock_version"), "#{key}/#{protection}"
        assert_equal posted[:external_id], entry.external_id
        assert_includes entry.transaction.extra.fetch("auto_claimed_pending_ids"), pending[:external_id]
        assert_equal protection != :user_modified, entry.transaction.pending?, "#{key}/#{protection}"
      end
    end
  end

  test "compatible financial field locks survive the source identity transition" do
    each_provider do |key, external, account|
      pending, posted = record(key, pending: true), record(key, pending: false, date: "2026-09-18")
      apply(external, pending)
      entry = account.entries.sole
      entry.update!(name: "Locked description", notes: "Locked note")
      %i[amount date name notes].each { |field| entry.lock_attr!(field) }
      before = entry.reload.attributes.slice("id", "amount", "currency", "date", "name", "notes", "locked_attributes")

      assert_no_difference("Entry.count") { apply(external, posted) }

      assert_equal before, entry.reload.attributes.slice(*before.keys), key
      assert_equal posted[:external_id], entry.external_id
      assert_not entry.transaction.pending?, key
    end
  end

  test "a locked alias document refuses atomically" do
    each_provider do |key, external, account|
      pending, posted = record(key, pending: true), record(key, pending: false)
      apply(external, pending)
      entry = account.entries.sole
      entry.lock_attr!(:amount)
      entry.lock_attr!(:date)
      entry.transaction.lock_attr!(:extra)
      before = [ entry.reload.attributes, entry.transaction.reload.attributes ]

      assert_no_difference [ "Entry.count", "SourceRecord.count", "EntrySource.count" ] do
        assert_raises(Ingestion::MappedEntryResolver::Conflict, key) { apply(external, posted) }
      end
      assert_equal before, [ entry.reload.attributes, entry.transaction.reload.attributes ], key
      assert_not SourceRecord.find_by!(external_account: external, external_id: pending[:external_id]).withdrawn?, key
    end
  end

  test "two exact pending candidates are an explicit conflict without partial alias writes" do
    each_provider do |key, external, account|
      apply(external, record(key, pending: true, id: "pending-one"), record(key, pending: true, id: "pending-two"))
      before = account.entries.order(:id).pluck(:id, :external_id)

      assert_no_difference [ "Entry.count", "SourceRecord.count", "EntrySource.count" ] do
        assert_raises(Ingestion::PendingTransactionMatch::Conflict, key) { apply(external, record(key, pending: false)) }
      end
      assert_equal before, account.entries.order(:id).pluck(:id, :external_id), key
      assert SourceRecord.where(external_account: external).none?(&:withdrawn?), key
    end
  end

  test "mismatched amount currency and dates do not reconcile a pending entry" do
    [ { amount: "-13" }, { currency: "EUR" }, { date: "2026-09-09" }, { date: "2026-09-19" } ].each do |change|
      each_provider do |key, external, account|
        pending = record(key, pending: true)
        apply(external, pending)
        original = account.entries.sole

        assert_difference "Entry.count", 1 do
          apply(external, record(key, pending: false, **change))
        end
        assert_equal pending[:external_id], original.reload.external_id, "#{key}/#{change.keys.first}"
        assert original.transaction.pending?
      end
    end
  end

  test "a bare pending Entry is never adopted without this external account's posting proof" do
    each_provider do |key, external, account|
      pending = record(key, pending: true)
      entry = account.entries.create!(name: pending[:name], amount: pending[:amount], currency: pending[:currency],
        date: pending[:date], source: key, external_id: pending[:external_id],
        entryable: Transaction.new(extra: { key => { "pending" => true } }))

      assert_difference "Entry.count", 1 do
        apply(external, record(key, pending: false))
      end
      assert_equal pending[:external_id], entry.reload.external_id, key
      assert_empty entry.entry_sources
    end
  end

  test "another provider's pending evidence cannot authorize settlement" do
    each_provider do |key, external, account|
      other = create_external_account(create_provider_connection)
      link = AccountProvider.create!(account: account, external_account: other)
      Account::SourcePolicy.select!(account: account, account_provider: link, resource: "transactions")
      pending = record(key, pending: true)
      foreign = Ingestion::Record.transaction(**pending.attributes.merge(external_id: "up_pending", metadata: {}))
      apply(other, foreign)
      original = account.entries.sole
      Account::SourcePolicy.select!(account: account, account_provider: external.account_provider, resource: "transactions")

      assert_difference("Entry.count", 1) { apply(external, record(key, pending: false)) }
      assert_equal "up_pending", original.reload.external_id, key
      assert SourceRecord.find_by!(external_account: other, external_id: "up_pending").pending?
    end
  end

  test "another external account's pending posting remains untouched" do
    each_provider do |key, external, account|
      other = create_external_account(external.provider_connection, external_id: "other-remote-account")
      other_account = account.family.accounts.create!(name: "Other pending owner", currency: "USD", balance: 100, accountable: Depository.new)
      link = AccountProvider.create!(account: other_account, external_account: other)
      Account::SourcePolicy.select!(account: other_account, account_provider: link, resource: "transactions")
      pending = record(key, pending: true)
      apply(other, pending)
      original = other_account.entries.sole

      assert_difference("Entry.count", 1) { apply(external, record(key, pending: false)) }

      assert_equal pending[:external_id], original.reload.external_id, key
      assert original.transaction.pending?
      assert_not_equal original.id, account.entries.sole.id
      assert_not SourceRecord.find_by!(external_account: other, external_id: pending[:external_id]).withdrawn?
    end
  end

  test "non-authoritative observations and corrupt posting identity cannot claim pending rows" do
    each_provider do |key, external, account|
      pending, posted = record(key, pending: true), record(key, pending: false)
      apply(external, pending)
      original = account.entries.sole
      original.update!(external_id: "#{key}_changed")
      assert_no_difference [ "Entry.count", "SourceRecord.count", "EntrySource.count" ] do
        assert_raises(Ingestion::MappedEntryResolver::Conflict, key) { apply(external, posted) }
      end

      other = create_external_account(create_provider_connection)
      link = AccountProvider.create!(account: account, external_account: other)
      Account::SourcePolicy.select!(account: account, account_provider: link, resource: "transactions")
      assert_no_difference([ "Entry.count", "EntrySource.count" ]) { apply(external, posted) }
      assert_nil SourceRecord.find_by!(external_account: external, external_id: posted[:external_id]).entry_source
      assert_equal "#{key}_changed", original.reload.external_id, key
    end
  end

  test "synthetic posted IDs do not opt in and altered policies cannot widen the exact window" do
    each_provider do |key, external, _account|
      if %w[akahu lunchflow].include?(key)
        assert_nil record(key, pending: false, id: nil)[:metadata][:pending_match_policy], key
      end
      apply(external, record(key, pending: true))
      posted = record(key, pending: false)
      changed = Ingestion::Record.transaction(**posted.attributes.merge(metadata: posted[:metadata].merge(
        pending_match_policy: posted[:metadata][:pending_match_policy].merge(backward_days: 90))))
      assert_no_difference [ "Entry.count", "SourceRecord.count", "EntrySource.count" ] do
        assert_raises(Ingestion::PendingTransactionMatch::Conflict, key) { apply(external, changed) }
      end
    end
  end

  private
    def each_provider
      with_provider_encryption do
        PROVIDERS.each do |key|
          connection = create_provider_connection(provider_key: key)
          external = create_external_account(connection, external_id: "remote-account")
          account = connection.family.accounts.create!(name: "#{key} settlement", currency: "USD", balance: 100, accountable: Depository.new)
          link = AccountProvider.create!(account: account, external_account: external)
          Account::SourcePolicy.select!(account: account, account_provider: link, resource: "transactions")
          yield key, external, account
        end
      end
    end

    def record(key, pending:, id: pending ? nil : "posted", amount: "-12", currency: "USD", date: pending ? "2026-09-10" : "2026-09-12")
      account = { external_id: "remote-account", currency: currency }
      name = pending ? "Pending provider name" : "Booked provider name"
      case key
      when "akahu"
        Provider::AccountData::Akahu.new(client: Object.new, timezone: "UTC").normalize_transaction(
          { _id: id, _account: "remote-account", amount: amount, currency: currency, date: date, description: name, pending: pending }, account: account)
      when "lunchflow"
        Provider::AccountData::Lunchflow.new(client: Object.new, timezone: "UTC", observed_at: Time.utc(2026, 9, 16), include_pending: true).normalize_transaction(
          { id: id, accountId: "remote-account", amount: amount, currency: currency, date: date, merchant: name, isPending: pending }, account: account)
      when "redbark"
        Provider::AccountData::Redbark.new(client: Object.new, timezone: "UTC", observed_at: Time.utc(2026, 9, 16), include_pending: true).normalize_transaction(
          { id: id || "pending", accountId: "remote-account", amount: amount, date: date, merchantName: name, status: pending ? "pending" : "posted" }, account: account)
      end
    end

    def apply(external, *records)
      page = Provider::AccountData::Page.new(records: records, complete: true, mode: "snapshot", coverage: { "pending_absence_authoritative" => false })
      policy = Account::SourcePolicy.active.find_by!(account: external.current_account, resource: "transactions")
      batch = create_provider_batch(external.provider_connection, external_account: external, stream: "transactions",
        payload: Ingestion::Codec.dump(page), source_policy_version: policy.id)
      IngestionBatch.transaction(requires_new: true) do
        Ingestion::LedgerWriter.new(external_account: external, batch: batch).apply(page)
        batch.update!(status: "applied", applied_at: Time.current)
      end
      batch
    end
end
