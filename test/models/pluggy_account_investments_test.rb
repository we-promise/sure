require "test_helper"

class PluggyAccountInvestmentsTest < ActiveSupport::TestCase
  test "investment columns exist" do
    cols = PluggyAccount.column_names
    %w[raw_holdings_payload raw_activities_payload cash_balance
       last_holdings_sync last_activities_sync activities_fetch_pending].each do |c|
      assert_includes cols, c, "missing column #{c}"
    end
  end

  test "holdings snapshot stores payload" do
    acct = pluggy_accounts(:one)
    acct.upsert_pluggy_holdings_snapshot!([ { "code" => "PETR4", "quantity" => 100 } ])
    assert_equal [ { "code" => "PETR4", "quantity" => 100 } ], acct.reload.raw_holdings_payload
  end

  test "activities snapshot stores payload" do
    acct = pluggy_accounts(:one)
    acct.upsert_pluggy_activities_snapshot!([ { "id" => "a1", "type" => "BUY" } ])
    assert_equal [ { "id" => "a1", "type" => "BUY" } ], acct.reload.raw_activities_payload
  end
end
