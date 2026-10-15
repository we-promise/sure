require "test_helper"

class TradeRepublic::AccountEditorComponentTest < ViewComponent::TestCase
  include TradeRepublicSessionTestHelper

  # The account fixtures ship unlinked (no account_providers rows); pairing
  # each with a Sure account puts an item into the fully set up state.
  def link_all_accounts(item)
    sure_accounts = accounts(:investment, :depository, :credit_card)
    item.trade_republic_accounts.each_with_index do |provider_account, index|
      AccountProvider.create!(account: sure_accounts.fetch(index), provider: provider_account)
    end
  end

  test "renders a card per item" do
    family = families(:dylan_family)
    items = [ trade_republic_items(:configured_item), trade_republic_items(:requires_update_item) ]

    render_inline(TradeRepublic::AccountEditorComponent.new(items: items, family: family))

    items.each do |item|
      assert_text item.name
    end
  end

  test "wraps each card in its own target for per-connection turbo streams" do
    item = trade_republic_items(:configured_item)

    render_inline(TradeRepublic::AccountEditorComponent.new(items: [ item ], family: families(:dylan_family)))

    assert_selector "##{TradeRepublic::ConnectionCardComponent.dom_id_for(item)}", text: item.name
  end

  test "adding another connection opens in the drawer" do
    render_inline(TradeRepublic::AccountEditorComponent.new(items: [ trade_republic_items(:configured_item) ], family: families(:dylan_family)))

    assert_selector "a[href='#{Rails.application.routes.url_helpers.new_trade_republic_pending_connection_path}'][data-turbo-frame='drawer']",
                    text: I18n.t("settings.providers.trade_republic_panel.add_account")
    assert_no_selector "form[action='#{Rails.application.routes.url_helpers.trade_republic_pending_connections_path}']", visible: :all
  end

  test "a new connection whose QR login just started shows its QR code" do
    family = families(:dylan_family)
    pending_connection = family.trade_republic_pending_connections.create!(qr_login: true, pending_login_state: "qr-pending")
    pending_connection.stubs(:login_stage).returns("qr_pending")

    render_inline(TradeRepublic::AccountEditorComponent.new(
      items: [],
      family: family,
      pending_connection: pending_connection,
      qr_code_svg: "<svg id='fresh-qr'></svg>".html_safe
    ))

    assert_selector "##{ActionView::RecordIdentifier.dom_id(pending_connection)} svg#fresh-qr", visible: :all
    assert_text I18n.t("settings.providers.trade_republic_panel.new_connection")
  end

  test "no other connection can be added while one is still logging in" do
    family = families(:dylan_family)
    family.trade_republic_pending_connections.create!(qr_login: true, pending_login_state: "qr-pending")

    render_inline(TradeRepublic::AccountEditorComponent.new(items: [ trade_republic_items(:configured_item) ], family: family))

    assert_no_link I18n.t("settings.providers.trade_republic_panel.add_account")
    assert_no_selector "form[action='#{Rails.application.routes.url_helpers.trade_republic_pending_connections_path}']", visible: :all
  end

  test "a new connection whose login lapsed can start a QR login again or be cancelled" do
    pending_connection = families(:dylan_family).trade_republic_pending_connections.create!(qr_login: true)

    render_inline(TradeRepublic::PendingConnectionCardComponent.new(pending_connection: pending_connection))

    assert_text I18n.t("settings.providers.trade_republic_panel.login_expired")
    assert_button I18n.t("settings.providers.trade_republic_panel.qr_login")
    assert_button I18n.t("settings.providers.trade_republic_panel.cancel_login")
  end

  test "a connection offers QR and PIN login next to sync and remove" do
    render_inline(TradeRepublic::ConnectionCardComponent.new(item: trade_republic_items(:configured_item)))

    %w[sync qr_login pin_login remove].each do |key|
      assert_button I18n.t("settings.providers.trade_republic_panel.#{key}")
    end
  end

  test "sync is offered only once the connection is logged in" do
    render_inline(TradeRepublic::ConnectionCardComponent.new(item: trade_republic_items(:requires_update_item)))

    assert_no_button I18n.t("settings.providers.trade_republic_panel.sync")
  end

  test "the PIN login form below a connection starts a login with the phone number and PIN" do
    item = trade_republic_items(:configured_item)

    render_inline(TradeRepublic::ConnectionCardComponent.new(item: item))

    form = "[data-trade-republic-pin-login-target='form'][hidden] form[action='#{Rails.application.routes.url_helpers.trade_republic_item_path(item)}']"
    assert_selector "#{form} input[name='_method'][value='patch']", visible: :all
    assert_selector "#{form} input[name='trade_republic_item[phone_number]']:not([required])", visible: :all
    assert_selector "#{form} input[name='trade_republic_item[pin]'][required]", visible: :all
  end

  test "a push login in progress hides the other ways to log in" do
    item = trade_republic_items(:configured_item)
    item.update!(pending_login_state: "pending")
    item.stubs(:login_stage).returns("waiting_for_approval")

    render_inline(TradeRepublic::ConnectionCardComponent.new(item: item))

    assert_text I18n.t("settings.providers.trade_republic_panel.push_login_notice")
    assert_no_button I18n.t("settings.providers.trade_republic_panel.qr_login")
    assert_no_button I18n.t("settings.providers.trade_republic_panel.pin_login")
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

    assert_selector "form[action='#{Rails.application.routes.url_helpers.trade_republic_pending_connections_path}']"
  end

  test "card summary shows the last 4 digits of the phone number" do
    item = trade_republic_items(:configured_item)

    render_inline(TradeRepublic::AccountEditorComponent.new(items: [ item ], family: families(:dylan_family)))

    assert_selector "##{TradeRepublic::ConnectionCardComponent.dom_id_for(item)}",
                    text: "#{I18n.t("settings.providers.trade_republic_panel.identifier_phone")} •••• 4567"
  end

  test "card summary shows the account number stored at login before the first sync" do
    family = families(:dylan_family)
    item = family.trade_republic_items.create!(
      name: "Trade Republic", currency: "EUR", status: :good, session_blob: "session", brokerage_account_id: "DE1122334455"
    )

    render_inline(TradeRepublic::ConnectionCardComponent.new(item: item))

    assert_text "#{I18n.t("settings.providers.trade_republic_panel.identifier_account")} •••• 4455"
  end

  test "card summary falls back to the account number when there is no phone number" do
    family = families(:dylan_family)
    item = family.trade_republic_items.create!(
      name: "Trade Republic", currency: "EUR", status: :requires_update, session_blob: "session"
    )
    item.trade_republic_accounts.create!(
      kind: "portfolio", trade_republic_account_id: "DE9876543210", currency: "EUR", raw_positions_payload: [], raw_timeline_payload: []
    )

    render_inline(TradeRepublic::AccountEditorComponent.new(items: [ item ], family: family))

    assert_selector "##{TradeRepublic::ConnectionCardComponent.dom_id_for(item)}",
                    text: "#{I18n.t("settings.providers.trade_republic_panel.identifier_account")} •••• 3210"
  end

  test "disconnect confirmation names the connection by its last 4 digits" do
    item = trade_republic_items(:configured_item)

    render_inline(TradeRepublic::ConnectionCardComponent.new(item: item))

    assert_selector "button[data-turbo-confirm*='4567']"
  end

  test "card summary shows no identifier for a connection with neither a phone number nor an account yet" do
    item = families(:dylan_family).trade_republic_items.create!(
      name: "Trade Republic", currency: "EUR", status: :requires_update, session_blob: "session"
    )

    render_inline(TradeRepublic::ConnectionCardComponent.new(item: item))

    assert_no_text "••••"
  end

  test "a failed connection attempt is redisplayed with its phone number" do
    family = families(:dylan_family)
    failed_connection = family.trade_republic_pending_connections.build(phone_number: "+491701234567")

    render_inline(TradeRepublic::AccountEditorComponent.new(items: [], family: family, new_connection: failed_connection))

    assert_selector "input[name='trade_republic_pending_connection[phone_number]'][value='+491701234567']"
  end

  test "a connected card shows when its login expires" do
    item = trade_republic_items(:configured_item)
    item.update!(session_blob: trade_republic_session_blob(expires_at: 5.hours.from_now))

    render_inline(TradeRepublic::AccountEditorComponent.new(items: [ item ], family: families(:dylan_family)))

    assert_text I18n.t("settings.providers.trade_republic_panel.session_expires_in",
                       time: "about 5 hours", at: I18n.l(item.session_expires_at, format: :short))
  end

  test "a card whose session expired asks to log in again" do
    item = trade_republic_items(:configured_item)
    item.update!(session_blob: trade_republic_session_blob(expires_at: 1.minute.ago))

    render_inline(TradeRepublic::AccountEditorComponent.new(items: [ item ], family: families(:dylan_family)))

    assert_selector ".text-destructive", text: I18n.t("settings.providers.trade_republic_panel.requires_update")
    assert_no_text I18n.t("settings.providers.trade_republic_panel.status_configured_prefix")
  end

  test "a card whose QR login lapsed can start a QR login again" do
    item = trade_republic_items(:requires_update_item)
    item.update!(pending_login_state: "lapsed-qr")
    item.stubs(:login_stage).returns("expired")

    render_inline(TradeRepublic::ConnectionCardComponent.new(item: item))

    assert_text I18n.t("settings.providers.trade_republic_panel.login_expired")
    assert_button I18n.t("settings.providers.trade_republic_panel.qr_login")
  end
end
