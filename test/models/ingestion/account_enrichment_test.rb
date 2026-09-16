require "test_helper"
require_relative "../../support/provider_ingestion_test_helper"

class Ingestion::AccountEnrichmentTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  test "account name and subtype enrichment use the existing objects and log provider provenance" do
    account = accounts(:depository)
    accountable_id = account.accountable_id
    metadata = { account_enrichment: { name: "Provider checking", subtype: "savings", accountable_type: "Depository" } }
    apply(account, metadata)
    assert_equal "Provider checking", account.reload.name
    assert_equal "savings", account.depository.subtype
    assert_equal accountable_id, account.accountable_id
    assert_equal "Provider checking", account.data_enrichments.find_by!(source: "plaid", attribute_name: "name").value
    assert_equal "savings", account.depository.data_enrichments.find_by!(source: "plaid", attribute_name: "subtype").value
  end

  test "replay preserves newly locked names and subtypes" do
    account = accounts(:depository)
    metadata = { account_enrichment: { name: "Provider name", subtype: "savings", accountable_type: "Depository" } }
    apply(account, metadata)
    account.update!(name: "My name")
    account.lock_attr!(:name)
    account.depository.update!(subtype: "checking")
    account.depository.lock_attr!(:subtype)
    assert_no_difference "DataEnrichment.count" do
      apply(account, metadata)
    end
    assert_equal "My name", account.reload.name
    assert_equal "checking", account.depository.reload.subtype
  end

  test "legacy credit updates preserve missing fields and retain the existing direct-update lock semantics" do
    account = accounts(:credit_card)
    account.credit_card.update!(minimum_payment: 50, apr: 20)
    account.credit_card.lock_attr!(:apr)
    hints = { accountable_type: "CreditCard", strategy: "update_non_null", attributes: { minimum_payment: nil, apr: BigDecimal("12.9") } }
    assert_no_difference "DataEnrichment.count" do
      apply(account, accountable_attributes: hints)
    end
    assert_equal BigDecimal("50"), account.credit_card.reload.minimum_payment
    assert_equal BigDecimal("12.9"), account.credit_card.apr
    assert account.credit_card.locked?(:apr)
  end

  test "explicit loan updates clear absent fields while true enrichments preserve locks and record provenance" do
    account = accounts(:loan)
    account.loan.update!(interest_rate: 5, initial_balance: 1000, term_months: 120)
    account.loan.lock_attr!(:interest_rate)
    apply(account, accountable_attributes: { accountable_type: "Loan", strategy: "update", attributes: {
      rate_type: "fixed", interest_rate: BigDecimal("4.75"), initial_balance: nil, term_months: 121
    } })
    assert_equal BigDecimal("4.75"), account.loan.reload.interest_rate
    assert_nil account.loan.initial_balance
    assert_equal 121, account.loan.term_months
    apply(account, accountable_attributes: { accountable_type: "Loan", strategy: "enrich", attributes: {
      interest_rate: BigDecimal("7"), initial_balance: BigDecimal("3000")
    } })
    assert_equal BigDecimal("4.75"), account.loan.reload.interest_rate
    assert_equal BigDecimal("3000"), account.loan.initial_balance
    assert account.loan.data_enrichments.exists?(source: "plaid", attribute_name: "initial_balance")
  end

  test "malformed types strategies monetary hints and arbitrary attributes cannot mutate the domain" do
    account = accounts(:credit_card)
    original = account.attributes
    variations = [
      false,
      [],
      { accountable_type: "Kernel", strategy: "update", attributes: {} },
      { accountable_type: "Loan", strategy: "update", attributes: {} },
      { accountable_type: "CreditCard", strategy: "destroy", attributes: {} },
      { accountable_type: "CreditCard", strategy: "update", attributes: { family_id: "another-family" } },
      { accountable_type: "CreditCard", strategy: "update", attributes: { apr: 0.1 } },
      { accountable_type: "CreditCard", strategy: "update", attributes: { apr: "12.9" } }
    ]
    variations.each do |liability|
      assert_raises(Provider::AccountData::InvalidResponse) do
        apply(account, account_enrichment: { name: "Must not save", subtype: "credit_card", accountable_type: "CreditCard" }, accountable_attributes: liability)
      end
      assert_equal original, account.reload.attributes
    end
  end

  test "balance publication applies typed enrichment under the selected source fence" do
    with_provider_encryption do
      Provider::AccountData::Registry.stubs(:fetch).with("plaid").returns(Provider::AccountData::Plaid)
      connection = create_provider_connection(provider_key: "plaid")
      external = create_external_account(connection)
      account = accounts(:credit_card)
      link = AccountProvider.create!(account: account, external_account: external)
      policy = Account::SourcePolicy.select!(account: account, account_provider: link, resource: "balances")
      record = Ingestion::Record.account(external_id: external.external_id, name: "Card", currency: "USD", balance: BigDecimal("123"),
        metadata: { account_enrichment: { name: "Provider card", subtype: "credit_card", accountable_type: "CreditCard" },
          accountable_attributes: { accountable_type: "CreditCard", strategy: "update_non_null", attributes: { minimum_payment: BigDecimal("10") } } })
      page = Provider::AccountData::Page.new(records: [ record ], complete: true)
      batch = create_provider_batch(connection, external_account: external, stream: "balances", source_policy_version: policy.id, payload: Ingestion::Codec.dump(page))
      IngestionBatch.transaction { Ingestion::LedgerWriter.new(external_account: external, batch: batch).apply(page) }
      assert_equal "Provider card", account.reload.name
      assert_equal BigDecimal("123"), account.balance
      assert_equal BigDecimal("10"), account.credit_card.minimum_payment
      other = create_external_account(create_provider_connection)
      other_link = AccountProvider.create!(account: account, external_account: other)
      Account::SourcePolicy.select!(account: account, account_provider: other_link, resource: "balances")
      assert_raises(Provider::AccountData::StaleWriter) { Ingestion::LedgerWriter.new(external_account: external, batch: batch).apply(page) }
    end
  end

  test "legacy category bootstrap occurs on an eligible row even with matching disabled and is idempotent on replay" do
    with_provider_encryption do
      family = families(:empty)
      assert_empty family.categories
      account = family.accounts.create!(name: "New linked account", currency: "USD", balance: 0, accountable: Depository.new(subtype: "checking"), enable_category_matcher: false)
      connection = create_provider_connection(family: family)
      external = create_external_account(connection)
      link = AccountProvider.create!(account: account, external_account: external)
      policy = Account::SourcePolicy.select!(account: account, account_provider: link, resource: "transactions")
      record = Ingestion::Record.transaction(external_id: "bootstrap-event", name: "Unclassified", amount: BigDecimal("1"), currency: "USD", date: Date.current, pending: false,
        metadata: { category_bootstrap: "empty_family" })
      page = Provider::AccountData::Page.new(records: [ record ], complete: true)
      batch = create_provider_batch(connection, external_account: external, stream: "transactions", source_policy_version: policy.id, payload: Ingestion::Codec.dump(page))
      writer = Ingestion::LedgerWriter.new(external_account: external, batch: batch)
      IngestionBatch.transaction { writer.apply(page) }
      assert family.categories.exists?
      assert_nil account.entries.find_by!(external_id: "bootstrap-event").transaction.category_id
      assert_no_difference "Category.count" do
        IngestionBatch.transaction { Ingestion::LedgerWriter.new(external_account: external, batch: batch).apply(page) }
      end
    end
  end

  private
    def apply(account, metadata)
      account.with_lock { Ingestion::AccountEnrichment.new(account: account, source: "plaid").apply!(metadata: metadata) }
    end
end
