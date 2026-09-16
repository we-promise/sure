require "test_helper"
require_relative "../../support/provider_ingestion_test_helper"

class Ingestion::LedgerWriterTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  test "refreshing a protected transaction preserves user values and records source evidence" do
    with_provider_encryption do
      external, account = linked_account
      entry = account.entries.create!(
        external_id: "up_preserved", source: "up", name: "My edited name",
        date: Date.current - 2, amount: 81, currency: "USD", user_modified: true,
        entryable: Transaction.new
      )
      page = transaction_page("up_preserved", amount: BigDecimal("94.12"))
      apply(external, page)

      assert_equal "My edited name", entry.reload.name
      assert_equal BigDecimal("81"), entry.amount
      assert_equal entry.id, SourceRecord.find_by!(external_account: external, external_id: "up_preserved").entry.id
    end
  end

  test "a cancelled hold releases the ledger entry and retains its original identity in evidence" do
    with_provider_encryption do
      external, account = linked_account
      apply(external, transaction_page("up_cancelled", pending: true))
      entry = account.entries.find_by!(external_id: "up_cancelled")
      evidence = EntrySource.find_by!(entry: entry)
      observation = evidence.source_record

      apply(external, empty_snapshot)

      assert_not Entry.exists?(entry.id)
      assert observation.reload.withdrawn?
      assert_not evidence.reload.active?
      assert_nil evidence.entry_id
      assert_equal entry.id, evidence.entry_identity
    end
  end

  test "absence in a partial page cannot remove a pending entry" do
    with_provider_encryption do
      external, account = linked_account
      apply(external, transaction_page("up_partial", pending: true))
      page = Provider::AccountData::Page.new(records: [], complete: false, mode: "snapshot", next_cursor: "next", coverage: coverage)
      apply(external, page)

      assert account.entries.find_by!(external_id: "up_partial").transaction.extra.dig("up", "pending")
    end
  end

  test "absence outside the covered dates cannot remove an older hold" do
    with_provider_encryption do
      external, account = linked_account
      apply(external, transaction_page("up_old", pending: true, date: Date.current - 30))
      apply(external, empty_snapshot)

      assert account.entries.find_by!(external_id: "up_old").transaction.extra.dig("up", "pending")
    end
  end

  test "cancellation preserves protected entries and clears only the source pending state" do
    with_provider_encryption do
      external, account = linked_account
      apply(external, transaction_page("up_locked", pending: true))
      entry = account.entries.find_by!(external_id: "up_locked")
      entry.update!(import_locked: true)

      apply(external, empty_snapshot)

      assert entry.reload.import_locked?
      assert_equal BigDecimal("91.37"), entry.amount
      assert_equal false, entry.transaction.extra.dig("up", "pending")
    end
  end

  test "another provider's evidence survives withdrawal of the original source" do
    with_provider_encryption do
      external, account = linked_account
      apply(external, transaction_page("up_corroborated", pending: true))
      entry = account.entries.find_by!(external_id: "up_corroborated")
      other_connection = create_provider_connection(provider_key: "plaid")
      other_external = create_external_account(other_connection)
      AccountProvider.create!(account: account, external_account: other_external)
      other_batch = create_provider_batch(other_connection, external_account: other_external, stream: "transactions")
      other_record = SourceRecord.create!(
        account: account, family: account.family, external_account: other_external,
        ingestion_batch: other_batch, kind: "transaction", external_id: "other-observation"
      )
      other_record.create_entry_source!(entry: entry, account: account, family: account.family, role: "evidence", match_method: "reviewed")

      apply(external, empty_snapshot)

      assert entry.reload
      assert_equal entry.id, other_record.reload.entry.id
      assert_equal false, entry.transaction.extra.dig("up", "pending")
    end
  end

  test "a sibling account's batch cannot be attached as source evidence" do
    with_provider_encryption do
      external, account = linked_account
      sibling = create_external_account(external.provider_connection)
      batch = create_provider_batch(external.provider_connection, external_account: sibling, stream: "transactions")
      source_record = SourceRecord.new(
        family: account.family, account: account, external_account: external,
        ingestion_batch: batch, kind: "transaction", external_id: "wrong-evidence"
      )

      assert_not source_record.valid?
      assert source_record.errors[:external_account].present?
    end
  end

  test "a complete feed without authoritative pending absence preserves a hold" do
    with_provider_encryption do
      external, account = linked_account
      apply(external, transaction_page("up_not_authoritative", pending: true))
      page = Provider::AccountData::Page.new(records: [], complete: true, mode: "snapshot",
        coverage: coverage.merge("pending_absence_authoritative" => false))
      apply(external, page)

      assert account.entries.find_by!(external_id: "up_not_authoritative").transaction.pending?
    end
  end

  test "older overlapping observations cannot regress a posted transaction" do
    with_provider_encryption do
      external, account = linked_account
      newer = transaction_page("up_ordered", amount: BigDecimal("40"), metadata: { observation_order: [ 1, 200, 1 ] })
      older = transaction_page("up_ordered", amount: BigDecimal("30"), pending: true, metadata: { observation_order: [ 0, 0, 0 ] })
      apply(external, newer)
      observation = SourceRecord.find_by!(external_account: external, external_id: "up_ordered")
      batch_id = observation.ingestion_batch_id
      apply(external, older)

      entry = account.entries.find_by!(external_id: "up_ordered")
      assert_equal BigDecimal("40"), entry.amount
      assert_not entry.transaction.pending?
      assert_equal batch_id, observation.reload.ingestion_batch_id
    end
  end

  test "identical idless occurrences retain separate financial identities across retries" do
    with_provider_encryption do
      external, account = linked_account
      records = 2.times.map do |occurrence|
        transaction_page("up_pending_equal", pending: true,
          metadata: { identity_policy: "reuse_pending_or_allocate_suffix", identity_occurrence: occurrence }).records.first
      end
      page = Provider::AccountData::Page.new(records: records, complete: true, mode: "snapshot", coverage: coverage)
      apply(external, page)
      identities = account.entries.where("external_id LIKE ?", "up_pending_equal%").pluck(:id, :external_id)
      assert_equal 2, identities.size
      assert_equal %w[up_pending_equal up_pending_equal_1], identities.map(&:last).sort
      apply(external, page)

      assert_equal identities.sort, account.entries.where("external_id LIKE ?", "up_pending_equal%").pluck(:id, :external_id).sort
      assert_equal [ 0, 1 ], SourceRecord.where(external_account: external, input_external_id: "up_pending_equal").order(:input_occurrence).pluck(:input_occurrence)
    end
  end

  test "a replacement connection cannot withdraw an earlier connection's hold" do
    with_provider_encryption do
      previous, account = linked_account
      apply(previous, transaction_page("up_prior_connection", pending: true))
      entry = account.entries.find_by!(external_id: "up_prior_connection")
      previous_policy = account.source_policies.active.sole
      previous_policy.update!(active: false)
      previous.account_provider.destroy!
      replacement = create_external_account(create_provider_connection)
      link = AccountProvider.create!(account: account, external_account: replacement)
      Account::SourcePolicy.select!(account: account, account_provider: link, resource: "transactions")

      apply(replacement, empty_snapshot)

      assert entry.reload.transaction.pending?
      assert_not SourceRecord.find_by!(external_account: previous, external_id: "up_prior_connection").withdrawn?
      assert_not previous_policy.reload.active?
      assert_equal previous.id, previous_policy.source_binding.fetch("external_account_id")
    end
  end

  test "withdrawn evidence does not keep a cancelled hold in the ledger" do
    with_provider_encryption do
      external, account = linked_account
      apply(external, transaction_page("up_withdrawn_evidence", pending: true))
      entry = account.entries.find_by!(external_id: "up_withdrawn_evidence")
      other = create_external_account(create_provider_connection(provider_key: "plaid"))
      AccountProvider.create!(account: account, external_account: other)
      other_batch = create_provider_batch(other.provider_connection, external_account: other, stream: "transactions")
      evidence = SourceRecord.create!(external_account: other, account: account, family: account.family,
        ingestion_batch: other_batch, kind: "transaction", external_id: "withdrawn", withdrawn: true)
      evidence.create_entry_source!(entry: entry, account: account, family: account.family, role: "evidence", match_method: "reviewed")

      apply(external, empty_snapshot)

      assert_not Entry.exists?(entry.id)
      assert evidence.reload.withdrawn?
      assert_nil evidence.entry_source
    end
  end

  test "an explicit withdrawal preserves financial identity in evidence across retries" do
    with_provider_encryption do
      external, account = linked_account
      apply(external, transaction_page("withdrawn-posting"))
      entry = account.entries.find_by!(external_id: "withdrawn-posting")
      apply(external, removal_page("withdrawn-posting"))
      assert_not Entry.exists?(entry.id)
      observation = SourceRecord.find_by!(external_account: external, external_id: "withdrawn-posting")
      assert observation.withdrawn?
      assert_equal entry.id, observation.entry_sources.sole.entry_identity
      assert_nil observation.entry_source
      assert_no_difference [ "Entry.count", "EntrySource.count", "SourceRecord.count" ] do
        apply(external, removal_page("withdrawn-posting"))
      end
    end
  end

  test "explicit removals preserve user edits and cannot delete an unbackfilled legacy identity" do
    with_provider_encryption do
      external, account = linked_account
      apply(external, transaction_page("protected-removal"))
      entry = account.entries.find_by!(external_id: "protected-removal")
      entry.update!(user_modified: true, notes: "Keep this")
      apply(external, removal_page("protected-removal"))
      assert_equal "Keep this", entry.reload.notes

      entry.entry_sources.destroy_all
      SourceRecord.where(external_account: external, external_id: "protected-removal").destroy_all
      assert_raises(Provider::AccountData::InvalidResponse) do
        apply(external, removal_page("protected-removal"))
      end
      assert entry.reload.user_modified?
    end
  end

  test "an unseen tombstone retains evidence without inventing a financial posting" do
    with_provider_encryption do
      external, = linked_account
      assert_no_difference "Entry.count" do
        apply(external, removal_page("never-posted"))
      end
      assert SourceRecord.find_by!(external_account: external, external_id: "never-posted").withdrawn?
    end
  end

  test "partial or contradictory removals cannot delete a posted transaction" do
    with_provider_encryption do
      external, account = linked_account
      original = transaction_page("inconsistent-removal")
      apply(external, original)
      partial = Provider::AccountData::Page.new(records: [], removed_ids: [ "inconsistent-removal" ], complete: false,
        coverage: { removal_policy: "exact_external_id" })
      assert_raises(Provider::AccountData::InvalidResponse) { apply(external, partial) }
      contradictory = Provider::AccountData::Page.new(records: original.records, removed_ids: [ "inconsistent-removal" ], complete: true,
        coverage: { removal_policy: "exact_external_id" })
      assert_raises(Provider::AccountData::InvalidResponse) { apply(external, contradictory) }
      assert account.entries.exists?(external_id: "inconsistent-removal")
    end
  end

  test "canonical merchant descriptors preserve provider logo and website when creating a transaction" do
    with_provider_encryption do
      external, account = linked_account
      details = { external_id: "source-merchant-with-logo", name: "Wallet asset", website_url: "https://example.test/asset",
        logo_url: "https://example.test/asset.png" }
      apply(external, transaction_page("merchant-logo-entry", metadata: { merchant: details }))

      merchant = account.entries.find_by!(external_id: "merchant-logo-entry").transaction.merchant
      assert_instance_of ProviderMerchant, merchant
      assert_equal "https://example.test/asset.png", merchant.logo_url
      assert_equal "https://example.test/asset", merchant.website_url
      assert_equal "source-merchant-with-logo", merchant.provider_merchant_id
      assert_equal "up", merchant.source
    end
  end

  test "a subsequent source transaction reuses merchant identity and supplies its current logo" do
    with_provider_encryption do
      external, account = linked_account
      merchant = ProviderMerchant.create!(source: "up", provider_merchant_id: "existing-merchant-logo", name: "Wallet asset",
        logo_url: "https://example.test/old.png")
      details = { external_id: "existing-merchant-logo", name: "Wallet asset", logo_url: "https://example.test/new.png" }
      assert_no_difference "ProviderMerchant.count" do
        apply(external, transaction_page("merchant-logo-refresh", metadata: { merchant: details }))
      end

      assert_equal merchant.id, account.entries.find_by!(external_id: "merchant-logo-refresh").transaction.merchant_id
      assert_equal "https://example.test/new.png", merchant.reload.logo_url
    end
  end

  test "pending absence and exact tombstones preserve individually locked and reconciled entries" do
    with_provider_encryption do
      external, account = linked_account
      [ :field_lock, :reconciled ].each do |protection|
        [ :absence, :tombstone ].each do |removal|
          identity = "preserved-#{protection}-#{removal}"
          apply(external, transaction_page(identity, pending: true))
          entry = account.entries.find_by!(external_id: identity)
          if protection == :field_lock
            entry.lock_attr!(:amount)
          else
            entry.update!(reconciled_at: Time.current)
          end
          original = entry.attributes.slice("amount", "currency", "date", "name")
          apply(external, removal == :absence ? empty_snapshot : removal_page(identity))

          assert_equal original, entry.reload.attributes.slice("amount", "currency", "date", "name")
          assert_not entry.transaction.pending?
          assert SourceRecord.find_by!(external_account: external, external_id: identity).withdrawn?
        end
      end
    end
  end

  test "publication rejects a cached account linkage after the link is removed" do
    with_provider_encryption do
      external, account = linked_account
      page = transaction_page("unlinked-during-fetch")
      policy = account.source_policies.active.sole
      binding = Provider::AccountData::GenerationAccounts.new(external.provider_connection).capture_one(external)
      batch = create_provider_batch(external.provider_connection, external_account: external, stream: "transactions",
        source_policy_version: policy.id, source_binding: binding, payload: Ingestion::Codec.dump(page))
      writer = Ingestion::LedgerWriter.new(external_account: external, batch: batch)
      policy.update!(active: false)
      external.account_provider.destroy!

      assert_no_difference [ "Entry.count", "SourceRecord.count" ] do
        assert_raises(Provider::AccountData::StaleWriter) { writer.apply(page) }
      end
    end
  end

  test "account publication supports explicit institution identity namespaces" do
    with_provider_encryption do
      connection = create_provider_connection
      external = create_external_account(connection, identity_namespace: "institution:one")
      account = accounts(:depository)
      link = AccountProvider.create!(account: account, external_account: external)
      Account::SourcePolicy.select!(account: account, account_provider: link, resource: "transactions")

      apply(external, transaction_page("institution-source"))

      assert account.entries.exists?(source: "up", external_id: "institution-source")
    end
  end

  test "an ordinary captured page without its original binding cannot adopt the current link" do
    with_provider_encryption do
      external, account = linked_account
      page = transaction_page("missing-original-binding")
      policy = account.source_policies.active.sole
      batch = create_provider_batch(external.provider_connection, external_account: external, stream: "transactions",
        source_policy_version: policy.id, source_binding: {}, payload: Ingestion::Codec.dump(page))
      external.account_provider.touch

      assert_no_difference [ "Entry.count", "SourceRecord.count" ] do
        assert_raises(Provider::AccountData::StaleWriter) do
          Ingestion::LedgerWriter.new(external_account: external, batch: batch).apply(page)
        end
      end
      assert batch.reload.captured?
      assert_empty batch.source_binding
    end
  end

  test "publication rejects financial currency changes after capture" do
    with_provider_encryption do
      external, account = linked_account
      page = transaction_page("changed-account-currency")
      batch = create_provider_batch(external.provider_connection, external_account: external, stream: "transactions",
        source_policy_version: account.source_policies.active.sole.id, payload: Ingestion::Codec.dump(page))
      account.update!(currency: "EUR")

      assert_no_difference [ "Entry.count", "SourceRecord.count" ] do
        assert_raises(Provider::AccountData::StaleWriter) do
          Ingestion::LedgerWriter.new(external_account: external, batch: batch).apply(page)
        end
      end
      assert_equal "USD", batch.source_binding.fetch("account_currency")
    end
  end

  test "publication rejects a financial account type change after capture" do
    with_provider_encryption do
      external, account = linked_account
      page = transaction_page("changed-account-type")
      batch = create_provider_batch(external.provider_connection, external_account: external, stream: "transactions",
        source_policy_version: account.source_policies.active.sole.id, payload: Ingestion::Codec.dump(page))
      account.update!(accountable: CreditCard.new)

      assert_no_difference [ "Entry.count", "SourceRecord.count" ] do
        assert_raises(Provider::AccountData::StaleWriter) do
          Ingestion::LedgerWriter.new(external_account: external, batch: batch).apply(page)
        end
      end
      assert_equal "Depository", batch.source_binding.fetch("accountable_type")
    end
  end

  test "captured source bindings cannot be replaced with a later link revision" do
    with_provider_encryption do
      external, account = linked_account
      batch = create_provider_batch(external.provider_connection, external_account: external, stream: "transactions",
        source_policy_version: account.source_policies.active.sole.id)
      captured = batch.source_binding.deep_dup
      external.account_provider.touch
      batch.source_binding = Provider::AccountData::GenerationAccounts.new(external.provider_connection).capture_one(external)

      assert_not batch.valid?
      assert batch.errors[:source_binding].present?
      assert_equal captured, batch.reload.source_binding
    end
  end

  test "withdrawals retain locked transaction metadata while updating source evidence" do
    with_provider_encryption do
      external, account = linked_account
      [ :absence, :tombstone ].each do |removal|
        identity = "locked-metadata-#{removal}"
        apply(external, transaction_page(identity, pending: true))
        entry = account.entries.find_by!(external_id: identity)
        entry.transaction.lock_attr!(:extra)
        original = [ entry.reload.attributes, entry.transaction.reload.attributes ]

        apply(external, removal == :absence ? empty_snapshot : removal_page(identity))

        assert_equal original, [ entry.reload.attributes, entry.transaction.reload.attributes ]
        assert SourceRecord.find_by!(external_account: external, external_id: identity).withdrawn?
      end
    end
  end

  private
    def removal_page(*ids)
      Provider::AccountData::Page.new(records: [], removed_ids: ids, complete: true,
        coverage: { removal_policy: "exact_external_id" })
    end

    def linked_account
      connection = create_provider_connection
      external = create_external_account(connection)
      account = accounts(:depository)
      link = AccountProvider.create!(account: account, external_account: external)
      Account::SourcePolicy.select!(account: account, account_provider: link, resource: "transactions")
      [ external, account ]
    end

    def coverage
      { "start" => 7.days.ago.utc.iso8601, "end" => Time.current.utc.iso8601 }
    end

    def transaction_page(external_id, amount: BigDecimal("91.37"), pending: false, date: Date.current - 3, metadata: {})
      record = Ingestion::Record.transaction(
        external_id: external_id, name: "Source description", currency: "USD",
        date: date, amount: amount, pending: pending, metadata: metadata
      )
      Provider::AccountData::Page.new(records: [ record ], complete: true, mode: "snapshot", coverage: coverage)
    end

    def empty_snapshot
      Provider::AccountData::Page.new(records: [], complete: true, mode: "snapshot", coverage: coverage)
    end

    def apply(external, page)
      policy = Account::SourcePolicy.active.find_by!(account: external.current_account, resource: "transactions")
      batch = create_provider_batch(
        external.provider_connection, external_account: external, stream: "transactions",
        payload: Ingestion::Codec.dump(page), source_policy_version: policy.id
      )
      IngestionBatch.transaction do
        Ingestion::LedgerWriter.new(external_account: external, batch: batch)
          .apply(page, observed_pending_ids: page.records.filter_map { |record| record[:external_id] if record[:pending] })
      end
    end
end
