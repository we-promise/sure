require "test_helper"
require_relative "../../../../support/provider_ingestion_test_helper"

class Provider::AccountData::Lunchflow::PostedMatchTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  include ActiveJob::TestHelper

  # Exercise the gated adapter through its production writer without changing
  # the declaration's readiness outside this test fixture.
  setup { Provider::AccountData::Lunchflow.stubs(:native_ready?).returns(true) }
  teardown { clear_enqueued_jobs }

  test "late pending retains evidence without modifying the protected posted entry" do
    with_provider_encryption do
      external, account = linked_account
      apply(external, page(posted))
      entry = account.entries.find_by!(source: "lunchflow", external_id: "lunchflow_posted")
      entry.update!(user_modified: true, import_locked: true, reconciled_at: Time.current, notes: "Keep my note")
      entry.lock_attr!(:amount)
      entry.transaction.lock_attr!(:extra)
      original = [ entry.reload.attributes, entry.transaction.reload.attributes ]

      batch = nil
      assert_no_difference [ "Entry.count", "Transaction.count" ] do
        batch = apply(external, page(pending))
      end

      observation = SourceRecord.find_by!(external_account: external, external_id: pending[:external_id])
      assert observation.pending?
      assert_not observation.withdrawn?
      assert_equal batch.id, observation.ingestion_batch_id
      assert_equal pending[:external_id], observation.input_external_id
      assert_equal "evidence", observation.entry_source.role
      assert_equal "lunchflow_posted_match", observation.entry_source.match_method
      assert_equal entry.id, observation.entry_source.entry_identity
      assert_equal original, [ entry.reload.attributes, entry.transaction.reload.attributes ]
      assert_equal pending.attributes, Ingestion::Codec.load(batch.reload.payload).records.sole.attributes
    end
  end

  test "posted then pending in the same captured page has one posting and one evidence mapping" do
    with_provider_encryption do
      external, account = linked_account
      batch = apply(external, page(posted, pending))

      assert_equal 1, account.entries.where(source: "lunchflow").count
      observations = SourceRecord.where(external_account: external, ingestion_batch: batch)
      assert_equal 2, observations.count
      assert_equal %w[evidence posting], EntrySource.where(source_record: observations).pluck(:role).sort
      assert_equal 1, EntrySource.where(source_record: observations).distinct.count(:entry_identity)
    end
  end

  test "repeat evidence follows its original posting after user edits instead of matching again" do
    with_provider_encryption do
      external, account = linked_account
      apply(external, page(posted))
      apply(external, page(pending))
      observation = SourceRecord.find_by!(external_account: external, external_id: pending[:external_id])
      original_mapping = observation.entry_source.attributes
      entry = observation.entry
      entry.update!(name: "My description", amount: 200, user_modified: true)
      original_entry = entry.attributes

      assert_no_difference [ "Entry.count", "Transaction.count", "SourceRecord.count", "EntrySource.count" ] do
        apply(external, page(pending))
      end

      assert_equal original_mapping, observation.reload.entry_source.attributes
      assert_equal original_entry, entry.reload.attributes
      assert_equal 1, account.entries.where(source: "lunchflow").count
    end
  end

  test "ambiguous posted matches refuse the whole pending publication" do
    with_provider_encryption do
      external, = linked_account
      apply(external, page(posted, posted(id: "other-posted")))
      before = EntrySource.order(:id).pluck(:id, :entry_identity, :role)

      assert_no_difference [ "Entry.count", "SourceRecord.count", "EntrySource.count" ] do
        assert_raises(Provider::AccountData::Lunchflow::PostedMatch::Conflict) do
          apply(external, page(pending))
        end
      end
      assert_equal before, EntrySource.order(:id).pluck(:id, :entry_identity, :role)
    end
  end

  test "two distinct pending occurrences cannot both claim one posted observation" do
    with_provider_encryption do
      external, = linked_account
      apply(external, page(posted))
      second = Ingestion::Record.transaction(**pending.attributes.merge(
        metadata: pending[:metadata].merge(identity_occurrence: 1)))

      assert_no_difference [ "Entry.count", "SourceRecord.count", "EntrySource.count" ] do
        assert_raises(Provider::AccountData::Lunchflow::PostedMatch::Conflict) do
          apply(external, page(pending, second))
        end
      end
    end
  end

  test "bare matching entries and other provider postings are never adopted" do
    with_provider_encryption do
      external, account = linked_account
      bare = account.entries.create!(name: "Coffee", amount: 12, currency: "USD", date: Date.new(2026, 9, 12),
        source: "lunchflow", external_id: "lunchflow_unproved", entryable: Transaction.new)
      other = create_external_account(create_provider_connection)
      other_link = AccountProvider.create!(account: account, external_account: other)
      Account::SourcePolicy.select!(account: account, account_provider: other_link, resource: "transactions")
      other_record = Ingestion::Record.transaction(**posted.attributes.merge(external_id: "up_other"))
      apply(other, page(other_record))
      other_entry = account.entries.find_by!(source: "up", external_id: "up_other")
      Account::SourcePolicy.select!(account: account, account_provider: external.account_provider, resource: "transactions")

      assert_difference "Entry.count", 1 do
        apply(external, page(pending))
      end
      evidence = SourceRecord.find_by!(external_account: external, external_id: pending[:external_id]).entry_source
      assert_equal "posting", evidence.role
      assert_not_includes [ bare.id, other_entry.id ], evidence.entry_identity
    end
  end

  test "amount currency date and supplied merchant must match exactly" do
    with_provider_encryption do
      external, account = linked_account
      apply(external, page(posted))
      variants = [ pending(amount: "-13"), pending(currency: "EUR"),
        pending(date: "2026-09-01"), pending(date: "2026-09-13"), pending(merchant: "Other merchant") ]
      assert_difference "Entry.count", variants.size do
        variants.each { |record| apply(external, page(record)) }
      end
      assert_equal variants.size, account.entries.where("external_id LIKE ?", "lunchflow_pending_%").count
      assert_empty EntrySource.where(match_method: "lunchflow_posted_match")
    end
  end

  test "another Lunchflow external account cannot supply the posting proof" do
    with_provider_encryption do
      external, = linked_account
      other = create_external_account(external.provider_connection, external_id: "lf-other")
      other_account = accounts(:credit_card)
      other_link = AccountProvider.create!(account: other_account, external_account: other)
      Account::SourcePolicy.select!(account: other_account, account_provider: other_link, resource: "transactions")
      apply(other, page(posted))

      assert_difference "Entry.count", 1 do
        apply(external, page(pending))
      end
      mapping = SourceRecord.find_by!(external_account: external, external_id: pending[:external_id]).entry_source
      assert_equal "posting", mapping.role
      assert_equal external.current_account.id, mapping.account_id
    end
  end

  test "a changed posted financial identity refuses suppression" do
    with_provider_encryption do
      external, account = linked_account
      apply(external, page(posted))
      entry = account.entries.find_by!(external_id: "lunchflow_posted", source: "lunchflow")
      entry.update!(external_id: "lunchflow_replaced")

      assert_no_difference [ "Entry.count", "SourceRecord.count", "EntrySource.count" ] do
        assert_raises(Ingestion::MappedEntryResolver::Conflict) do
          apply(external, page(pending))
        end
      end
    end
  end

  test "missing merchant does not require the fallback description to match" do
    with_provider_encryption do
      external, = linked_account
      apply(external, page(posted))
      no_merchant = pending(merchant: nil)

      assert_no_difference "Entry.count" do
        apply(external, page(no_merchant))
      end
      assert_equal "evidence", SourceRecord.find_by!(external_account: external,
        external_id: no_merchant[:external_id]).entry_source.role
    end
  end

  test "a withdrawn posted source invalidates retained suppression instead of creating a new entry" do
    with_provider_encryption do
      external, = linked_account
      apply(external, page(posted))
      apply(external, page(pending))
      source = SourceRecord.find_by!(external_account: external, external_id: posted[:external_id])
      source.update!(withdrawn: true)

      assert_no_difference [ "Entry.count", "SourceRecord.count", "EntrySource.count" ] do
        assert_raises(Provider::AccountData::Lunchflow::PostedMatch::Conflict) do
          apply(external, page(pending))
        end
      end
    end
  end

  test "unselected Lunchflow records remain observations without financial matching" do
    with_provider_encryption do
      external, account = linked_account
      apply(external, page(posted))
      other = create_external_account(create_provider_connection)
      other_link = AccountProvider.create!(account: account, external_account: other)
      Account::SourcePolicy.select!(account: account, account_provider: other_link, resource: "transactions")

      assert_no_difference [ "Entry.count", "EntrySource.count" ] do
        apply(external, page(pending))
      end
      observation = SourceRecord.find_by!(external_account: external, external_id: pending[:external_id])
      assert observation.pending?
      assert_nil observation.entry_source
    end
  end

  test "an altered match policy cannot widen the provider-specific window" do
    with_provider_encryption do
      external, = linked_account
      apply(external, page(posted))
      invalid = Ingestion::Record.transaction(**pending.attributes.merge(metadata: pending[:metadata].merge(
        posted_match_policy: pending[:metadata][:posted_match_policy].merge(forward_days: 90))))

      assert_no_difference [ "Entry.count", "SourceRecord.count", "EntrySource.count" ] do
        assert_raises(Provider::AccountData::Lunchflow::PostedMatch::Conflict) do
          apply(external, page(invalid))
        end
      end
    end
  end

  private
    def linked_account
      connection = create_provider_connection(provider_key: "lunchflow", credentials: { "api_key" => "private-key" })
      external = create_external_account(connection, external_id: "lf-account")
      account = accounts(:depository)
      link = AccountProvider.create!(account: account, external_account: external)
      Account::SourcePolicy.select!(account: account, account_provider: link, resource: "transactions")
      [ external, account ]
    end

    def posted(**overrides)
      normalized({ id: "posted", accountId: "lf-account", amount: "-12", currency: "USD",
        date: "2026-09-12", merchant: "Coffee", description: "Provider note", isPending: false }.merge(overrides))
    end

    def pending(**overrides)
      normalized({ id: nil, accountId: "lf-account", amount: "-12", currency: "USD",
        date: "2026-09-10", merchant: "Coffee", description: "Provider note", isPending: true }.merge(overrides))
    end

    def normalized(raw)
      adapter = Provider::AccountData::Lunchflow.new(client: Object.new, timezone: "UTC",
        observed_at: Time.utc(2026, 9, 16), include_pending: true)
      adapter.normalize_transaction(raw, account: { external_id: "lf-account", currency: "USD" })
    end

    def page(*records)
      Provider::AccountData::Page.new(records: records, complete: true, mode: "snapshot",
        coverage: { "pending_absence_authoritative" => false })
    end

    def apply(external, page)
      policy = Account::SourcePolicy.active.find_by!(account: external.current_account, resource: "transactions")
      batch = create_provider_batch(external.provider_connection, external_account: external,
        stream: "transactions", payload: Ingestion::Codec.dump(page), source_policy_version: policy.id)
      IngestionBatch.transaction(requires_new: true) do
        Ingestion::LedgerWriter.new(external_account: external, batch: batch).apply(page)
        batch.update!(status: "applied", applied_at: Time.current)
      end
      batch
    end
end
