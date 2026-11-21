require "test_helper"

# The viewer's share is applied in Ruby (Account#owned_balance_for, the balance
# sheet, account views) and in SQL (Balance::ChartSeriesBuilder). These pin both
# to the same figure so one can't drift from the other.
class OwnershipParityTest < ActiveSupport::TestCase
  include BalanceTestHelper

  # [owner's percentage, co-owner's percentage]
  PERCENTAGES = [ [ 100, 100 ], [ 60, 40 ], [ 50, 50 ], [ 33.33, 66.67 ], [ 0, 100 ] ].freeze

  setup do
    @owner = users(:family_admin)
    @co_owner = users(:family_member)
    @account = accounts(:depository)
    @account.balances.destroy_all
    create_balance(account: @account, date: Date.current, balance: 1_234.56)
    @account.update_columns(balance: 1_234.56)

    # A second shared account with other figures: if the SQL share lookup lost
    # its account match, one account would pick up the other's percentage.
    @other = @account.family.accounts.create!(
      name: "Second shared account", balance: 800, currency: "USD", accountable: Depository.new, owner: @owner
    )
    create_balance(account: @other, date: Date.current, balance: 800)
    @other.account_shares.create!(user: @co_owner, permission: "read_only", include_in_finances: true)
  end

  test "Ruby, balance sheet and chart agree for the owner and the co-owner" do
    PERCENTAGES.each do |owner_pct, co_owner_pct|
      @account.update!(ownership_percentage: owner_pct)
      @account.account_shares.find_by!(user: @co_owner).update!(ownership_percentage: co_owner_pct)
      account = Account.find(@account.id)

      [ @owner, @co_owner ].each do |viewer|
        expected = account.owned_balance_for(viewer)
        label = "#{viewer.email} at #{account.ownership_percentage_for(viewer)}%"

        assert_in_delta expected, balance_sheet_balance(viewer, account), 0.01, "balance sheet row, #{label}"
        assert_in_delta expected, chart_balance(account, user: viewer), 0.01, "chart series, #{label}"
      end
    end
  end

  test "two shared accounts with different percentages each keep their own" do
    PERCENTAGES.each_with_index do |(owner_pct, co_owner_pct), i|
      other_owner_pct, other_co_owner_pct = PERCENTAGES[(i + 1) % PERCENTAGES.size]
      set_percentages(@account, owner_pct, co_owner_pct)
      set_percentages(@other, other_owner_pct, other_co_owner_pct)
      accounts = [ @account, @other ].map { |a| Account.find(a.id) }

      [ @owner, @co_owner ].each do |viewer|
        accounts.each do |account|
          assert_in_delta account.owned_balance_for(viewer), balance_sheet_balance(viewer, account), 0.01,
                          "balance sheet row #{account.name}, #{viewer.email}"
        end

        # The fragment the sparkline key reads, with a quoted viewer id.
        shares = Account.where(id: accounts.map(&:id))
          .pluck(:id, Arel.sql(Account.viewer_percentage_sql(Account.connection.quote(viewer.id)))).to_h
        accounts.each do |account|
          assert_in_delta account.ownership_percentage_for(viewer), shares[account.id], 0.001,
                          "sparkline key percentage #{account.name}, #{viewer.email}"
        end

        assert_in_delta accounts.sum { |a| a.owned_balance_for(viewer) },
                        chart_balance(accounts, user: viewer), 0.01,
                        "chart over both accounts, #{viewer.email}, pair #{i}"
      end
    end
  end

  test "without a viewer every surface counts the whole account" do
    @account.update!(ownership_percentage: 40)
    account = Account.find(@account.id)

    assert_in_delta account.balance, chart_balance(account, user: nil), 0.01
    assert_in_delta account.balance, balance_sheet_balance(nil, account), 0.01
  end

  private
    def set_percentages(account, owner_pct, co_owner_pct)
      account.update!(ownership_percentage: owner_pct)
      account.account_shares.find_by!(user: @co_owner).update!(ownership_percentage: co_owner_pct)
    end

    def balance_sheet_balance(viewer, account)
      sheet = BalanceSheet.new(account.family, user: viewer)
      row = sheet.account_groups.flat_map(&:accounts).find { |a| a.id == account.id }
      row.converted_balance.to_f
    end

    def chart_balance(accounts, user:)
      accounts = Array(accounts)
      Balance::ChartSeriesBuilder.new(
        account_ids: accounts.map(&:id),
        currency: accounts.first.family.currency,
        period: Period.last_30_days,
        interval: "1 day",
        user: user
      ).balance_series.last.value.amount.to_f
    end
end
