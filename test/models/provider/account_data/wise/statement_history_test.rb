require "test_helper"
require_relative "../../../../support/provider_ingestion_test_helper"

class Provider::AccountData::Wise::StatementHistoryTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  History = Provider::AccountData::Wise::StatementHistory

  setup do
    Provider::AccountData::Registry.stubs(:fetch).with("wise").returns(Provider::AccountData::Wise)
  end

  test "promotion and its first actual posting commit or roll back together" do
    with_source do |connection, external, account|
      page = statement_page(external)
      batch = batch_for(connection, external, page)
      assert_no_difference [ "Entry.count", "SourceRecord.count", "EntrySource.count", "ProviderSyncCheckpoint.count" ] do
        connection.with_lock(requires_new: true) do
          publish(external, batch, page)
          raise ActiveRecord::Rollback
        end
      end
      assert batch.reload.captured?
      assert_nil capture(external)

      connection.with_lock { publish(external, batch, page) }
      receipt = capture(external).receipt
      assert_equal batch.id, receipt.fetch("batch_id")
      assert_equal account.entries.sole.id, receipt.dig("posting", "entry_identity")
      checkpoint = connection.provider_sync_checkpoints.find_by!(stream: History::STREAM)
      assert_nil checkpoint.ingestion_batch_id
      assert_nil checkpoint.covered_through
      assert_nil checkpoint.cursor
      assert_provider_column_encrypted(checkpoint, :state, "statement-1")
      assert receipt.frozen?
    end
  end

  test "empty suppressed and non-statement pages cannot establish statement history" do
    with_source do |connection, external, _account|
      client = mock("suppressed Wise statement")
      client.expects(:get_balance_statement_page).returns(items: [ raw_statement.merge("amount" => { "value" => "-20", "currency" => "EUR" }) ], next_cursor: nil)
      adapter = Provider::AccountData::Wise.new(client: client, profile_id: "profile", timezone: "UTC")
      record = Ingestion::Record.account(external_id: external.external_id, currency: "EUR", name: "EUR", account_type: "STANDARD",
        metadata: { transaction_policy: { legacy_transfer_cutoff: "2026-01-01" } })
      suppressed = adapter.fetch_transactions(account: record, window: { start: "2026-01-01T00:00:00Z", end: "2026-01-20T00:00:00Z" })
      assert_empty suppressed.records
      empty = Provider::AccountData::Page.new(records: [], complete: true, mode: "snapshot", evidence: { "phase" => "statements" })
      transfers = Provider::AccountData::Page.new(records: statement_page(external).records, complete: true, mode: "snapshot", evidence: { "phase" => "transfers" })
      [ suppressed, empty, transfers ].each do |page|
        batch = batch_for(connection, external, page)
        connection.with_lock { publish(external, batch, page) }
        assert_nil capture(external)
      end
    end
  end

  test "an applied secondary observation cannot promote an existing financial entry" do
    with_source do |connection, external, account|
      other = create_provider_connection
      other_link = AccountProvider.create!(account: account, external_account: create_external_account(other, currency: "EUR"))
      Account::SourcePolicy.select!(account: account, account_provider: other_link, resource: "transactions")
      page = statement_page(external)
      batch = batch_for(connection, external, page)
      connection.with_lock { publish(external, batch, page) }
      assert batch.applied?
      assert_equal 1, SourceRecord.where(external_account: external).count
      assert_empty account.entries
      assert_empty EntrySource.where(source_record: SourceRecord.where(external_account: external))
      assert_nil capture(external)
    end
  end

  test "first receipt remains historical through later observations economic edits and entry deletion" do
    with_source do |connection, external, account|
      page = statement_page(external)
      first = batch_for(connection, external, page)
      connection.with_lock { publish(external, first, page) }
      original = capture(external).receipt
      entry = account.entries.sole
      entry.update!(name: "User edit", amount: 99, date: Date.new(2026, 2, 1))
      assert_equal original, capture(external).receipt

      second = batch_for(connection, external, page)
      connection.with_lock { publish(external, second, page) }
      assert_equal second.id, SourceRecord.where(external_account: external).sole.ingestion_batch_id
      assert_equal original, capture(external).receipt
      assert_equal 1, connection.provider_sync_checkpoints.where(stream: History::STREAM).count

      entry.reload.destroy!
      assert_nil EntrySource.find(original.dig("posting", "entry_source_id")).entry_id
      assert_equal original, capture(external).receipt
    end
  end

  test "the fixed factory clock cannot adopt its own promotion including an exact timestamp tie" do
    with_source do |connection, external, _account|
      page = statement_page(external)
      batch = batch_for(connection, external, page)
      observed_at = Time.current
      connection.with_lock { publish(external, batch, page) }
      assert_nil History.capture(external_account: external, observed_at: observed_at)
      assert_nil History.capture(external_account: external, observed_at: batch.reload.applied_at)
      assert History.capture(external_account: external, observed_at: batch.applied_at + 1.second)
    end
  end

  test "retained promotion rejects link policy profile and original payload drift" do
    %i[link policy profile payload].each do |drift|
      with_source do |connection, external, account|
        page = statement_page(external)
        batch = batch_for(connection, external, page)
        connection.with_lock { publish(external, batch, page) }
        case drift
        when :link then external.account_provider.update!(updated_at: 1.second.from_now)
        when :policy
          other = create_provider_connection
          link = AccountProvider.create!(account: account, external_account: create_external_account(other, currency: "EUR"))
          Account::SourcePolicy.select!(account: account, account_provider: link, resource: "transactions")
          Account::SourcePolicy.select!(account: account, account_provider: external.account_provider, resource: "transactions")
        when :profile then connection.update!(settings: { "profile_id" => "replacement-profile" })
        when :payload
          # Deliberate trusted SQL bypass exercises retained proof verification.
          batch.update_columns(payload: batch.payload.merge("complete" => false))
        end
        assert_raises(Provider::AccountData::StaleWriter) { capture(external) }
      end
    end
  end

  test "missing historical posting proof cannot silently restore transfer fallback" do
    with_source do |connection, external, _account|
      page = statement_page(external)
      batch = batch_for(connection, external, page)
      connection.with_lock { publish(external, batch, page) }
      receipt = capture(external).receipt
      EntrySource.where(id: receipt.dig("posting", "entry_source_id")).delete_all
      assert_raises(Provider::AccountData::StaleWriter) { capture(external) }
    end
  end

  test "oversized stored receipt is rejected before its encrypted state is materialized" do
    with_source do |connection, external, _account|
      page = statement_page(external)
      batch = batch_for(connection, external, page)
      connection.with_lock { publish(external, batch, page) }
      checkpoint = connection.provider_sync_checkpoints.find_by!(stream: History::STREAM)
      checkpoint.update_columns(state: { "oversized" => SecureRandom.hex(History::MAX_STATE_BYTES) })
      assert_operator ProviderSyncCheckpoint.where(id: checkpoint.id).pick(Arel.sql("octet_length(state::text)")), :>, History::MAX_STATE_BYTES
      ProviderSyncCheckpoint.any_instance.expects(:state).never
      assert_raises(Provider::AccountData::IncompletePage) { capture(external) }
    end
  end

  private
    def with_source
      with_provider_encryption do
        connection = create_provider_connection(provider_key: "wise", credentials: { token: "private-token" }, settings: { profile_id: "profile" })
        external = create_external_account(connection, external_id: "balance-1", currency: "EUR", account_type: "STANDARD")
        account = connection.family.accounts.create!(name: "Wise statement receipt", currency: "EUR", balance: 100, accountable: Depository.new)
        link = AccountProvider.create!(account: account, external_account: external)
        Account::SourcePolicy.select!(account: account, account_provider: link, resource: "transactions")
        yield connection, external, account
      end
    end

    def raw_statement
      { "referenceNumber" => "statement-1", "date" => "2026-01-10T00:00:00Z", "amount" => { "value" => "20", "currency" => "EUR" } }
    end

    def statement_page(external)
      adapter = Provider::AccountData::Wise.new(client: Object.new, profile_id: "profile", timezone: "UTC")
      record = Ingestion::Record.account(external_id: external.external_id, currency: "EUR", name: "EUR")
      Provider::AccountData::Page.new(records: adapter.normalize_statement(raw_statement, account: record), complete: false,
        next_cursor: "remaining-wise-history", mode: "snapshot", evidence: {
          "phase" => "statements", "response" => [ raw_statement ],
          "wise_account" => { "profile_id" => "profile", "external_id" => external.external_id, "currency" => "EUR" }
        })
    end

    def batch_for(connection, external, page)
      policy = Account::SourcePolicy.active.find_by!(account: external.current_account, resource: "transactions")
      create_provider_batch(connection, external_account: external, stream: "transactions", scope_key: "account:#{external.id}",
        source_policy_version: policy.id, complete: page.complete?, mode: page.mode, payload: Ingestion::Codec.dump(page))
    end

    def publish(external, batch, page)
      Ingestion::LedgerWriter.new(external_account: external, batch: batch).apply(page)
      batch.update!(status: "applied", applied_at: Time.current)
      History.record_applied!(external_account: external, batch: batch, page: page)
    end

    def capture(external)
      History.capture(external_account: external.reload, observed_at: 1.second.from_now)
    end
end
