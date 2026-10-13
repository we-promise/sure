require "test_helper"

class DS::SelectTest < ViewComponent::TestCase
  test "child? is true for an item whose object has a present parent_id" do
    select = DS::Select.new(
      form: nil,
      method: :category_id,
      items: [ categories(:subcategory) ]
    )

    item = select.items.first
    assert select.child?(item)
  end

  test "child? is false for an item whose object has no parent_id" do
    select = DS::Select.new(
      form: nil,
      method: :category_id,
      items: [ categories(:food_and_drink) ]
    )

    item = select.items.first
    assert_not select.child?(item)
  end

  test "child? is false for objects that don't respond to parent_id" do
    select = DS::Select.new(
      form: nil,
      method: :merchant_id,
      items: [ merchants(:netflix) ]
    )

    item = select.items.first
    assert_not select.child?(item)
  end

  test "child? is false for the include_blank placeholder item" do
    select = DS::Select.new(
      form: nil,
      method: :category_id,
      items: [ categories(:subcategory) ],
      include_blank: "Uncategorized"
    )

    blank_item = select.items.first
    assert_nil blank_item[:object]
    assert_not select.child?(blank_item)
  end

  test "the logo variant shows the selected item's logo on the closed trigger" do
    Setting.stubs(:brand_fetch_client_id).returns("test-client")
    account = accounts(:depository)
    account.update!(institution_domain: "example-bank.com")

    render_select(variant: :logo, items: [ account ], selected: account.id)

    assert_selector "button[data-select-target=button] [data-select-logo] img[src*='example-bank.com']"
    assert_selector "button[data-select-target=button]", text: account.name
  end

  test "the logo variant falls back to a lettermark on the closed trigger" do
    account = accounts(:depository)

    render_select(variant: :logo, items: [ account ], selected: account.id)

    assert_selector "button[data-select-target=button] [data-select-logo]"
    assert_no_selector "button[data-select-target=button] img"
  end

  test "the simple variant keeps a plain-text trigger" do
    account = accounts(:depository)

    render_select(variant: :simple, items: [ account ], selected: account.id)

    assert_no_selector "button[data-select-target=button] [data-select-logo]"
    assert_selector "button[data-select-target=button]", text: account.name
  end

  private
    def render_select(**options)
      with_request_url "/" do
        render_inline(DS::Select.new(form: form_builder, method: :account_id, **options))
      end
    end

    def form_builder
      ActionView::Helpers::FormBuilder.new(:transfer_match, nil, vc_test_controller.view_context, {})
    end
end
