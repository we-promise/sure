require "test_helper"

class Trading212ItemBroadcastRenderTest < ActiveSupport::TestCase
  setup do
    @item = trading212_items(:configured_item)
    @shared_account = accounts(:depository)  # shared with family_member
    @private_account = accounts(:investment) # not shared with family_member

    AccountProvider.create!(account: @private_account, provider: trading212_accounts(:main_account))
    second_t212_account = @item.trading212_accounts.create!(
      name: "Trading 212 CFD",
      trading212_account_id: "t212_acc_789",
      currency: "USD"
    )
    AccountProvider.create!(account: @shared_account, provider: second_t212_account)
  end

  teardown { Current.reset }

  test "renders without a current user and leaks no account rows" do
    Current.reset
    assert_nil Current.user

    html = render_card

    assert_not_includes html, ERB::Util.html_escape(@shared_account.name)
    assert_not_includes html, ERB::Util.html_escape(@private_account.name)
  end

  test "broadcast status partials render without a current user and contain no account rows" do
    Current.reset
    assert_nil Current.user

    %w[sync_status sync_summary].each do |partial|
      html = ApplicationController.render(
        partial: "trading212_items/#{partial}",
        locals: { trading212_item: @item.reload }
      )

      assert_includes html, "id=\"#{partial}_trading212_item_#{@item.id}\""
      assert_not_includes html, ERB::Util.html_escape(@shared_account.name)
      assert_not_includes html, ERB::Util.html_escape(@private_account.name)
    end
  end

  test "only lists accounts the viewing member can access" do
    Current.session = users(:family_member).sessions.create!(user_agent: "test", ip_address: "127.0.0.1")

    html = render_card

    assert_includes html, ERB::Util.html_escape(@shared_account.name)
    assert_not_includes html, ERB::Util.html_escape(@private_account.name)
  end

  private
    def render_card
      ApplicationController.render(
        partial: "trading212_items/trading212_item",
        locals: { trading212_item: @item.reload }
      )
    end
end
