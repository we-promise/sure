require "test_helper"

class Etoro::AccountEditorComponentTest < ViewComponent::TestCase
  setup do
    @item = etoro_items(:configured_item)
  end

  test "disconnecting a connection warns, once copies are recorded, that their history goes with it" do
    assert_equal I18n.t("settings.providers.etoro_panel.disconnect_confirm"), disconnect_confirm

    etoro_accounts(:main_account).portfolio_snapshots.create!(mirror_id: 7, date: Date.current, total: 100, cash: 10, username: "trader")

    confirm = JSON.parse(disconnect_confirm)
    assert_equal I18n.t("etoro_items.deletion_confirm.title"), confirm["title"]
    assert_equal I18n.t("etoro_items.deletion_confirm.body"), confirm["body"]
  end

  test "each connection's form and the new connection form have fields of their own" do
    other = @item.family.etoro_items.create!(name: "Second eToro", api_key: "second_public_key", user_key: "second_user_key")

    render_inline(Etoro::AccountEditorComponent.new(items: [ @item, other ], family: @item.family))

    ids = page.all("input[type=password]", visible: :all).map { |input| input[:id] }
    assert_equal 6, ids.size
    assert_equal ids.uniq, ids
    page.all("label.form-field__label", visible: :all).each do |label|
      assert page.has_css?("input[id='#{label[:for]}']", visible: :all), "#{label[:for]} labels a field of its own form"
    end
  end

  private

    # The confirmation the panel's Disconnect asks for, in the connection's
    # card whether it is open or not.
    def disconnect_confirm
      render_inline(Etoro::AccountEditorComponent.new(items: [ @item ], family: @item.family))
      page.find("button[aria-label='#{I18n.t("settings.providers.etoro_panel.disconnect")}']", visible: :all)["data-turbo-confirm"]
    end
end
