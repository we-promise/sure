require "test_helper"

class SimplefinItem::ImporterErrlistTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = SimplefinItem.create!(
      family: @family,
      name: "SF Conn",
      access_url: "https://example.com/access"
    )
    @sync = Sync.create!(syncable: @item)
  end

  test "records a v2 connection auth error from its code and message" do
    importer = importer_with(
      accounts: [ { id: "acct-1", name: "Checking" } ],
      errlist: [ { code: "con.auth", msg: "Action required", conn_id: "conn-1" } ]
    )

    result = importer.send(:fetch_accounts_data, start_date: 30.days.ago)

    assert_equal [ { id: "acct-1", name: "Checking" } ], result[:accounts]
    stats = @sync.reload.sync_stats
    assert_equal 1, stats.dig("error_buckets", "auth").to_i
    assert_equal "Action required", stats["errors"].first["message"]
    assert_equal "good", @item.reload.status
  end

  test "connection auth without accounts fails without invalidating the access url" do
    importer = importer_with(
      accounts: [],
      errlist: [ { code: "con.auth", msg: "Action required", conn_id: "conn-1" } ]
    )

    assert_raises(Provider::Simplefin::SimplefinError) do
      importer.send(:fetch_accounts_data, start_date: 30.days.ago)
    end

    assert_equal "good", @item.reload.status
  end

  test "general auth without accounts invalidates the access url" do
    importer = importer_with(
      accounts: [],
      errlist: [ { code: "gen.auth", msg: "Credentials rejected" } ]
    )

    assert_raises(Provider::Simplefin::SimplefinError) do
      importer.send(:fetch_accounts_data, start_date: 30.days.ago)
    end

    assert_equal "requires_update", @item.reload.status
  end

  test "general auth with cached accounts still invalidates the access url" do
    importer = importer_with(
      accounts: [ { id: "acct-1", name: "Checking" } ],
      errlist: [ { code: "gen.auth", msg: "Credentials rejected" } ]
    )

    assert_raises(Provider::Simplefin::SimplefinError) do
      importer.send(:fetch_accounts_data, start_date: 30.days.ago)
    end

    assert_equal "requires_update", @item.reload.status
  end

  test "prefers errlist when a transitional server also returns legacy errors" do
    importer = importer_with(
      accounts: [ { id: "acct-1", name: "Checking" } ],
      errlist: [ { code: "con.auth", msg: "Structured message", conn_id: "conn-1" } ],
      errors: [ "Legacy duplicate" ]
    )

    importer.send(:fetch_accounts_data, start_date: 30.days.ago)

    errors = @sync.reload.sync_stats["errors"]
    assert_equal 1, errors.size
    assert_equal "Structured message", errors.first["message"]
  end

  private

    def importer_with(payload)
      provider = mock()
      provider.expects(:get_accounts).returns(payload)
      SimplefinItem::Importer.new(@item, simplefin_provider: provider, sync: @sync)
    end
end
