require "test_helper"

class TradeRepublic::AccountEditorComponentTest < ViewComponent::TestCase
  test "renders a card per item and an add-connection form" do
    family = families(:dylan_family)
    items = [ trade_republic_items(:configured_item), trade_republic_items(:requires_update_item) ]

    render_inline(TradeRepublic::AccountEditorComponent.new(items: items, family: family))

    items.each do |item|
      assert_text item.name
    end
    assert_selector "form[action='#{Rails.application.routes.url_helpers.trade_republic_items_path}']"
  end

  test "renders only the add-connection form when the family has no items" do
    family = families(:empty)

    render_inline(TradeRepublic::AccountEditorComponent.new(items: [], family: family))

    assert_selector "form[action='#{Rails.application.routes.url_helpers.trade_republic_items_path}']"
  end
end
