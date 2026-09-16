require "test_helper"
require_relative "../support/provider_ingestion_test_helper"

class SourceRecordTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  test "a provider observation can exist before account setup but cannot manufacture financial evidence" do
    with_provider_encryption do
      observation, = unbound_observation
      assert_nil observation.account_id
      assert_nil observation.entry_source
      entry = entries(:transaction)
      evidence = observation.entry_sources.build(account: entry.account, family: entry.account.family, entry: entry,
        entry_identity: entry.id, role: "evidence", match_method: "unapproved")
      assert_not evidence.valid?
      assert_database_rejects(evidence)
    end
  end

  test "first publication binds an existing source identity without recreating it" do
    with_provider_encryption do
      observation, external = unbound_observation
      identity = observation.id
      account = accounts(:depository)
      link = AccountProvider.create!(account: account, external_account: external)
      policy = Account::SourcePolicy.select!(account: account, account_provider: link, resource: "transactions")
      record = Ingestion::Record.transaction(external_id: observation.external_id, name: "Retained purchase", amount: BigDecimal("12.34"),
        currency: "USD", date: Date.current, pending: false)
      page = Provider::AccountData::Page.new(records: [ record ], complete: true, mode: "delta")
      batch = create_provider_batch(external.provider_connection, external_account: external, stream: "transactions",
        scope_key: "account:#{external.id}", source_policy_version: policy.id, payload: Ingestion::Codec.dump(page))
      assert_no_difference "SourceRecord.count" do
        assert_difference "account.entries.count", 1 do
          Ingestion::LedgerWriter.new(external_account: external, batch: batch).apply(page)
        end
      end
      observation.reload
      assert_equal identity, observation.id
      assert_equal account.id, observation.account_id
      assert_equal batch.id, observation.ingestion_batch_id
      assert_equal account.entries.find_by!(external_id: observation.external_id).id, observation.entry.id
    end
  end

  test "editing a link alone cannot bind old retained evidence to a financial account" do
    with_provider_encryption do
      observation, external = unbound_observation
      account = accounts(:depository)
      link = AccountProvider.create!(account: account, external_account: external)
      Account::SourcePolicy.select!(account: account, account_provider: link, resource: "transactions")
      observation.account = account
      assert_not observation.valid?
      assert observation.errors[:account].present?
      assert_nil observation.reload.account_id
    end
  end

  test "unbound provider observations still require their exact account batch in the database" do
    with_provider_encryption do
      observation, external = unbound_observation
      sibling = create_external_account(external.provider_connection)
      sibling_batch = create_provider_batch(external.provider_connection, external_account: sibling, stream: "transactions")
      observation.ingestion_batch = sibling_batch
      assert_not observation.valid?
      assert_database_rejects(observation)
    end
  end

  test "a bound source identity cannot be cleared or moved to another account" do
    with_provider_encryption do
      connection = create_provider_connection
      external = create_external_account(connection)
      account = accounts(:depository)
      AccountProvider.create!(account: account, external_account: external)
      batch = create_provider_batch(connection, external_account: external, stream: "transactions")
      observation = SourceRecord.create!(family: account.family, account: account, external_account: external,
        ingestion_batch: batch, kind: "transaction", external_id: "fixed-financial-target")
      observation.account = nil
      assert_not observation.valid?
      assert observation.errors[:account].present?
      observation.account = accounts(:investment)
      assert_not observation.valid?
      assert observation.errors[:account].present?
      assert_equal account.id, observation.reload.account_id
    end
  end

  private
    def unbound_observation
      connection = create_provider_connection
      external = create_external_account(connection)
      batch = create_provider_batch(connection, external_account: external, stream: "transactions", scope_key: "account:#{external.id}")
      observation = SourceRecord.create!(family: connection.family, external_account: external,
        ingestion_batch: batch, kind: "transaction", external_id: "source-before-link")
      [ observation, external ]
    end
end
