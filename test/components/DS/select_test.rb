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

  test "a disabled select shows its value without a submitted field" do
    account = accounts(:depository)

    render_select(variant: :logo, items: [ account ], selected: account.id, disabled: true)

    assert_selector "button[data-select-target=button][disabled] [data-select-logo]"
    assert_no_selector "input[type=hidden][name='transfer_match[account_id]']", visible: :all
  end

  test "falls back to the placeholder, not the include_blank item's own label, when nothing is selected" do
    render_inline DS::Select.new(
      form: form_builder_for(Category.new, "category"),
      method: :parent_id,
      items: [ { value: 1, label: "Groceries" } ],
      selected: nil,
      placeholder: "Select a Category",
      include_blank: "(none)"
    )

    assert_selector "button#parent_id_trigger", text: "Select a Category"
    refute_selector "button#parent_id_trigger", text: "(none)"
  end

  test "shows the selected item's label when a real item is selected" do
    render_inline DS::Select.new(
      form: form_builder_for(Category.new, "category"),
      method: :parent_id,
      items: [ { value: 1, label: "Groceries" } ],
      selected: 1,
      placeholder: "Select a Category",
      include_blank: "(none)"
    )

    assert_selector "button#parent_id_trigger", text: "Groceries"
    refute_selector "button#parent_id_trigger span"
  end

  test "shows a selected item's short label below sm and its full label from sm up" do
    render_inline DS::Select.new(
      form: form_builder_for(Category.new, "category"),
      method: :parent_id,
      items: [
        { value: "USD", label: "United States Dollar (USD)", short_label: "USD" },
        { value: "EUR", label: "Euro (EUR)", short_label: "EUR" }
      ],
      selected: "EUR"
    )

    assert_selector "button#parent_id_trigger span.sm\\:hidden", text: "EUR"
    assert_selector "button#parent_id_trigger span.hidden.sm\\:inline", text: "Euro (EUR)", visible: :all
    assert_selector "[role=option][data-value=USD][data-short-label=USD][data-filter-name='United States Dollar (USD)'] span.sm\\:hidden", text: "USD", visible: :all
    assert_selector "[role=option][data-value=USD] span.hidden.sm\\:inline", text: "United States Dollar (USD)", visible: :all
  end

  test "searchable: :compact keeps the search field and hides its placeholder below sm" do
    render_inline DS::Select.new(
      form: form_builder_for(Category.new, "category"),
      method: :parent_id,
      items: [ { value: 1, label: "Groceries" } ],
      searchable: :compact
    )

    search = page.find("input[data-list-filter-target=input]", visible: :all)
    assert_equal I18n.t("helpers.select.search_placeholder"), search[:placeholder]
    assert_selector "div[class~='[&_input]:placeholder:text-transparent'][class~='sm:[&_input]:placeholder:text-secondary'] input[data-list-filter-target=input]", visible: :all
  end

  test "searchable: true keeps the placeholder at every width" do
    render_inline DS::Select.new(
      form: form_builder_for(Category.new, "category"),
      method: :parent_id,
      items: [ { value: 1, label: "Groceries" } ],
      searchable: true
    )

    assert_selector "input[data-list-filter-target=input]", visible: :all
    assert_no_selector "div[class*='placeholder:text-transparent']", visible: :all
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

    def form_builder_for(object, name)
      StyledFormBuilder.new(name, object, vc_test_controller.view_context, {})
    end
end
