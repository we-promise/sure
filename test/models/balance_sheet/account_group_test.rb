require "test_helper"

class BalanceSheet::AccountGroupTest < ActiveSupport::TestCase
  test "groups accounts by institution without changing their configured order" do
    fineco_usd = account("Fineco", "USD", 92)
    revolut = account("Revolut", "EUR", 20)
    fineco_eur = account("Fineco", "EUR", 100)
    manual = account(nil, "EUR", 5)
    unnamed = account(" ", "EUR", 10)

    groups = group([ revolut, fineco_usd, manual, fineco_eur, unnamed ]).institution_groups

    assert_equal [ "Fineco", "Revolut", nil ], groups.map(&:name)
    assert_equal [ fineco_usd, fineco_eur ], groups.first.accounts
    assert_equal [ manual, unnamed ], groups.last.accounts
    assert_equal 5, groups.sum { |institution| institution.accounts.size }
  end

  test "bank subtotal sums converted balances and preserves report exclusions" do
    eur = account("Fineco", "EUR", 100)
    usd = account("Fineco", "USD", 92)
    excluded = account("Fineco", "CHF", 500, excluded: true)

    bank = group([ eur, usd, excluded ]).institution_groups.sole

    assert_equal Money.new(192, "EUR"), bank.total_money
    assert_equal [ eur, usd, excluded ], bank.accounts
  end

  private
    def account(institution, currency, converted_balance, excluded: false)
      Account.new(institution_name: institution, currency: currency).tap do |account|
        account.stubs(:converted_balance).returns(converted_balance)
        account.stubs(:exclude_from_reports?).returns(excluded)
      end
    end

    def group(accounts)
      classification = BalanceSheet::ClassificationGroup.new(classification: "asset", currency: "EUR", accounts: accounts)
      BalanceSheet::AccountGroup.new(name: "Cash", color: Depository.color, accountable_type: Depository,
        accounts: accounts, classification_group: classification)
    end
end
