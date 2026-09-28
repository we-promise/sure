# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20260928090000_normalize_trade_republic_activity_labels")

class NormalizeTradeRepublicActivityLabelsMigrationTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @cash = @family.accounts.create!(
      name: "Trade Republic Cash", balance: 0, currency: "EUR", accountable: Depository.new(subtype: "checking")
    )
    @portfolio = @family.accounts.create!(
      name: "Trade Republic Portfolio", balance: 0, currency: "EUR", accountable: Investment.new(subtype: "brokerage")
    )
  end

  test "maps translated labels on investment accounts to fixed activity labels" do
    deposit = create_transaction(@portfolio, "Storting")
    interest = create_transaction(@portfolio, "Rente")
    fee = create_transaction(@portfolio, "Kaartkosten")

    run_migration

    assert_equal "Contribution", deposit.reload.investment_activity_label
    assert_equal "Interest", interest.reload.investment_activity_label
    assert_equal "Fee", fee.reload.investment_activity_label
  end

  test "clears deposit, withdrawal and card labels on the cash account" do
    transactions = [ "Storting", "Opname", "Kaartbetaling", "Card payment", "Belastingteruggaaf" ].map do |label|
      create_transaction(@cash, label)
    end

    run_migration

    transactions.each { |transaction| assert_nil transaction.reload.investment_activity_label }
  end

  test "maps a round up on the cash account to Buy" do
    round_up = create_transaction(@cash, "Round up")

    run_migration

    assert_equal "Buy", round_up.reload.investment_activity_label
  end

  test "clears English deposit and withdrawal labels the importer stored on the cash account" do
    withdrawal = create_transaction(@cash, "Withdrawal")
    deposit = create_transaction(@cash, "Contribution")

    run_migration

    assert_nil withdrawal.reload.investment_activity_label
    assert_nil deposit.reload.investment_activity_label
  end

  test "keeps English cash labels set by the user or a rule" do
    user_modified = create_transaction(@cash, "Withdrawal")
    user_modified.entry.update!(user_modified: true)
    locked = create_transaction(@cash, "Withdrawal")
    locked.lock_attr!(:investment_activity_label)
    rule_set = create_transaction(@cash, "Withdrawal")
    rule_set.data_enrichments.create!(attribute_name: "investment_activity_label", value: "Withdrawal", source: "rule")

    run_migration

    assert_equal "Withdrawal", user_modified.reload.investment_activity_label
    assert_equal "Withdrawal", locked.reload.investment_activity_label
    assert_equal "Withdrawal", rule_set.reload.investment_activity_label
  end

  test "keeps locked translated labels" do
    locked = create_transaction(@portfolio, "Storting")
    locked.lock_attr!(:investment_activity_label)

    run_migration

    assert_equal "Storting", locked.reload.investment_activity_label
  end

  test "leaves fixed labels, other providers and unknown values alone" do
    listed = create_transaction(@portfolio, "Withdrawal")
    other_provider = create_transaction(@cash, "Storting", source: "plaid")
    unknown = create_transaction(@cash, "Something else")

    run_migration

    assert_equal "Withdrawal", listed.reload.investment_activity_label
    assert_equal "Storting", other_provider.reload.investment_activity_label
    assert_equal "Something else", unknown.reload.investment_activity_label
  end

  test "can be run again" do
    deposit = create_transaction(@portfolio, "Storting")

    2.times { run_migration }

    assert_equal "Contribution", deposit.reload.investment_activity_label
  end

  private

    def create_transaction(account, label, source: "trade_republic")
      account.entries.create!(
        name: "Entry",
        amount: -10,
        currency: "EUR",
        date: Date.current,
        source: source,
        external_id: SecureRandom.uuid,
        entryable: Transaction.new(investment_activity_label: label)
      ).transaction
    end

    def run_migration
      ActiveRecord::Migration.suppress_messages do
        NormalizeTradeRepublicActivityLabels.new.up
      end
    end
end
