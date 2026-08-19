require "test_helper"

class DS::EmptyStateTest < ViewComponent::TestCase
  test "renders a centered wrapper with title and description" do
    render_inline(DS::EmptyState.new(icon: "repeat", title: "No data yet", description: "Add something."))

    assert_selector "div.text-center.items-center"
    assert_selector "p.text-primary", text: "No data yet"
    assert_selector "p.text-secondary", text: "Add something."
  end

  test "description is optional" do
    render_inline(DS::EmptyState.new(icon: "repeat", title: "Empty"))

    assert_selector "p.text-primary", text: "Empty"
    assert_no_selector "p.text-secondary"
  end

  test "renders the action slot" do
    render_inline(DS::EmptyState.new(icon: "repeat", title: "Empty")) do |es|
      es.with_action { "<a href='/go'>Go</a>".html_safe }
    end

    assert_selector "a[href='/go']", text: "Go"
  end

  test "passthrough class merges onto the wrapper" do
    render_inline(DS::EmptyState.new(icon: "repeat", title: "Empty", class: "custom-x"))

    assert_selector "div.custom-x.text-center"
  end
end
