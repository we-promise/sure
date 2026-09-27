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

  test "wraps each card in its own target for per-connection turbo streams" do
    item = trade_republic_items(:configured_item)

    render_inline(TradeRepublic::AccountEditorComponent.new(items: [ item ], family: families(:dylan_family)))

    assert_selector "##{TradeRepublic::ConnectionCardComponent.dom_id_for(item)} details"
  end

  test "a single connection renders expanded" do
    item = trade_republic_items(:configured_item)

    render_inline(TradeRepublic::AccountEditorComponent.new(items: [ item ], family: families(:dylan_family)))

    assert_selector "##{TradeRepublic::ConnectionCardComponent.dom_id_for(item)} details[open]"
  end

  test "with several connections only those needing attention render expanded" do
    healthy = trade_republic_items(:configured_item)
    needs_update = trade_republic_items(:requires_update_item)

    render_inline(TradeRepublic::AccountEditorComponent.new(items: [ healthy, needs_update ], family: families(:dylan_family)))

    assert_no_selector "##{TradeRepublic::ConnectionCardComponent.dom_id_for(healthy)} details[open]"
    assert_selector "##{TradeRepublic::ConnectionCardComponent.dom_id_for(needs_update)} details[open]"
  end

  test "the connection whose QR login just started renders expanded with its QR code" do
    healthy = trade_republic_items(:configured_item)
    other = trade_republic_items(:no_session_item)

    render_inline(TradeRepublic::AccountEditorComponent.new(
      items: [ healthy, other ],
      family: families(:dylan_family),
      qr_code_svg: "<svg id='fresh-qr'></svg>".html_safe,
      qr_login_auto_poll_item: healthy
    ))

    assert_selector "##{TradeRepublic::ConnectionCardComponent.dom_id_for(healthy)} details[open] svg#fresh-qr"
    assert_no_selector "##{TradeRepublic::ConnectionCardComponent.dom_id_for(other)} details[open]"
  end

  test "connections scheduled for deletion are not rendered" do
    family = families(:dylan_family)
    deleted = trade_republic_items(:requires_update_item)
    deleted.update_column(:scheduled_for_deletion, true)

    render_inline(TradeRepublic::AccountEditorComponent.new(family: family))

    assert_text trade_republic_items(:configured_item).name
    assert_no_text deleted.name
  end

  test "renders only the add-connection form when the family has no items" do
    family = families(:empty)

    render_inline(TradeRepublic::AccountEditorComponent.new(items: [], family: family))

    assert_selector "form[action='#{Rails.application.routes.url_helpers.trade_republic_items_path}']"
  end
end
