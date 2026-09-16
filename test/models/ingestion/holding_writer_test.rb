require "test_helper"
require_relative "../../support/provider_ingestion_test_helper"

class Ingestion::HoldingWriterTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  test "holding refresh preserves UUID and manual cost basis and security choices" do
    with_provider_encryption do
      external, account, security = linked_holding_account
      holding = apply(external, security, quantity: "3", cost_basis: "8")
      replacement = Security.create!(ticker: "CUSTOM:USER_CHOICE", name: "User choice", offline: true)
      holding.update!(cost_basis: 42, cost_basis_source: "manual", cost_basis_locked: true,
        security: replacement, security_locked: true)

      refreshed = apply(external, security, quantity: "4", cost_basis: "9")

      assert_equal holding.id, refreshed.id
      assert_equal replacement.id, refreshed.security_id
      assert_equal BigDecimal("42"), refreshed.cost_basis
      assert_equal BigDecimal("4"), refreshed.qty
      assert_equal holding.id, SourceRecord.find_by!(external_account: external, kind: "holding").holding_source.holding_id
    end
  end

  test "secondary position observations cannot overwrite the selected holding source" do
    with_provider_encryption do
      external, account, security = linked_holding_account
      holding = apply(external, security, quantity: "3", cost_basis: "8")
      secondary = create_external_account(create_provider_connection(provider_key: "simplefin"))
      AccountProvider.create!(account: account, external_account: secondary)

      assert_no_difference "Holding.count" do
        apply(secondary, security, quantity: "90", cost_basis: "12")
      end

      assert_equal BigDecimal("3"), holding.reload.qty
      assert_nil SourceRecord.find_by!(external_account: secondary, kind: "holding").holding_source
    end
  end

  test "deleting a holding retains its original identity in source evidence" do
    with_provider_encryption do
      external, _account, security = linked_holding_account
      holding = apply(external, security, quantity: "3", cost_basis: "8")
      evidence = holding.holding_sources.first
      holding.destroy!

      assert_not evidence.reload.active?
      assert_nil evidence.holding_id
      assert_equal holding.id, evidence.holding_identity
    end
  end

  test "selecting another source cannot silently complete an unresolved position handover" do
    with_provider_encryption do
      external, account, security = linked_holding_account
      holding = apply(external, security, quantity: "3", cost_basis: "8")
      secondary = create_external_account(create_provider_connection(provider_key: "simplefin"))
      link = AccountProvider.create!(account: account, external_account: secondary)
      Account::SourcePolicy.select!(account: account, account_provider: link, resource: "holdings")

      assert_raises(Provider::AccountData::InvalidResponse) do
        apply(secondary, security, quantity: "90", cost_basis: "12", external_id: "different-position-id")
      end

      assert_equal BigDecimal("3"), holding.reload.qty
      assert_equal external.account_provider.id, holding.account_provider_id
      assert_not SourceRecord.exists?(external_account: secondary)
    end
  end

  test "separate source components cannot overwrite the same financial position" do
    with_provider_encryption do
      external, _account, security = linked_holding_account
      holding = apply(external, security, quantity: "3", cost_basis: "8", external_id: "spot-position")
      assert_raises(Provider::AccountData::InvalidResponse) do
        apply(external, security, quantity: "7", cost_basis: "8", external_id: "earn-position")
      end
      assert_equal BigDecimal("3"), holding.reload.qty
      assert_equal "spot-position", holding.external_id
      assert_equal 1, SourceRecord.where(external_account: external, kind: "holding").count
    end
  end

  private
    def linked_holding_account
      external = create_external_account(create_provider_connection)
      account = accounts(:investment)
      link = AccountProvider.create!(account: account, external_account: external)
      Account::SourcePolicy.select!(account: account, account_provider: link, resource: "holdings")
      security = Security.create!(ticker: "CUSTOM:SOURCE_HOLDING", name: "Source holding", offline: true)
      [ external, account, security ]
    end

    def apply(external, security, quantity:, cost_basis:, external_id: "source-position")
      record = Ingestion::Record.holding(external_id: external_id, currency: "USD", date: Date.current,
        quantity: BigDecimal(quantity), price: BigDecimal("10"), amount: BigDecimal(quantity) * 10,
        security: { ticker: security.ticker }, metadata: { cost_basis: BigDecimal(cost_basis) })
      page = Provider::AccountData::Page.new(records: [ record ], complete: true, mode: "snapshot")
      policy = Account::SourcePolicy.active.find_by!(account: external.current_account, resource: "holdings")
      batch = create_provider_batch(external.provider_connection, external_account: external, stream: "holdings",
        payload: Ingestion::Codec.dump(page), source_policy_version: policy.id)
      IngestionBatch.transaction do
        Ingestion::LedgerWriter.new(external_account: external, batch: batch,
          securities: { [ "holding", external_id ] => security }).apply(page)
      end
      external.current_account.holdings.find_by(external_id: external_id)
    end
end
