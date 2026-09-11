require "test_helper"

class DS::IconPickerTest < ViewComponent::TestCase
  test "renders one filterable label per icon, keyed by icon code" do
    render_icon_picker(icons: %w[pizza coffee dog])

    assert_selector "label.filterable-item", count: 3
    assert_selector "label.filterable-item[data-filter-name='pizza']"
    assert_selector "label.filterable-item[data-filter-name='coffee']"
    assert_selector "label.filterable-item[data-filter-name='dog']"
  end

  test "wires the list-filter controller with a search input and empty message" do
    render_icon_picker(icons: %w[pizza])

    assert_selector "[data-controller='list-filter']"
    assert_selector "input[type='search'][data-list-filter-target='input']"
    assert_selector "[data-list-filter-target='list']"
    assert_selector "[data-list-filter-target='emptyMessage']", text: "No matching icons", visible: :all
  end

  test "prevents Enter in the search field from submitting the form" do
    render_icon_picker(icons: %w[pizza])

    action = page.find("input[type='search']")["data-action"]
    assert_includes action, "input->list-filter#filter"
    assert_includes action, "keydown.enter->list-filter#filter:prevent"
  end

  test "preserves the color-icon-picker contract on each radio" do
    render_icon_picker(icons: %w[pizza])

    radio = page.find("input[type='radio']", visible: :all)
    assert_equal "icon", radio["data-color-icon-picker-target"]
    assert_includes radio["data-action"], "change->color-icon-picker#handleIconChange"
    assert_includes radio["data-action"], "change->color-icon-picker#handleIconColorChange"

    assert_selector "label.filterable-item > input[type='radio'] + div > svg", visible: :all
  end

  test "binds radios to the method it was given" do
    render_icon_picker(icons: %w[pizza])
    assert_selector "input[name='category[lucide_icon]']", visible: :all

    render_inline DS::IconPicker.new(
      form: form_builder_for(Goal.new, "goal"),
      method: :icon,
      icons: %w[pizza]
    )
    assert_selector "input[name='goal[icon]']", visible: :all
  end

  private
    def render_icon_picker(icons:)
      render_inline DS::IconPicker.new(
        form: form_builder_for(Category.new, "category"),
        method: :lucide_icon,
        icons: icons
      )
    end

    def form_builder_for(object, name)
      StyledFormBuilder.new(name, object, vc_test_controller.view_context, {})
    end
end
