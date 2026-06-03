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
    assert_selector "h3", text: "Nothing yet"
    assert_no_selector "p"
    assert_no_selector "svg"
  end

  test "renders description when provided" do
    render_inline(DS::EmptyState.new(title: "Empty", description: "Add your first row to begin."))

    assert_selector "p", text: "Add your first row to begin."
  end

  test "renders icon when provided" do
    render_inline(DS::EmptyState.new(title: "Empty", icon: "chart-bar"))

    assert_selector "svg"
  end

  test "card variant adds bg-container chrome" do
    render_inline(DS::EmptyState.new(title: "Empty", variant: :card))

    assert_selector "div.bg-container.rounded-xl.shadow-border-xs"
  end

  test "plain variant omits card chrome" do
    render_inline(DS::EmptyState.new(title: "Empty", variant: :plain))

    assert_no_selector "div.bg-container.rounded-xl.shadow-border-xs"
  end

  test "unknown variant falls back to :card" do
    render_inline(DS::EmptyState.new(title: "Empty", variant: :nonexistent))

    assert_selector "div.bg-container.rounded-xl.shadow-border-xs"
  end

  test "unknown size falls back to :md" do
    render_inline(DS::EmptyState.new(title: "Empty", size: :nonexistent))

    # :md → h3.text-lg + py-12 px-6
    assert_selector "h3.text-lg"
    assert_selector "div.py-12.px-6"
  end

  test "unknown icon_style falls back to :plain" do
    render_inline(DS::EmptyState.new(title: "Empty", icon: "target", icon_style: :nonexistent))

    # :plain renders no disc wrapper
    assert_no_selector "div.bg-surface-inset"
    assert_selector "svg"
  end

  test "unknown heading_tag falls back to :h3" do
    render_inline(DS::EmptyState.new(title: "Empty", heading_tag: :div))

    assert_selector "h3", text: "Empty"
  end

  test "heading_tag overrides the title element" do
    render_inline(DS::EmptyState.new(title: "Empty", heading_tag: :h2))

    assert_selector "h2", text: "Empty"
    assert_no_selector "h3"
  end

  test "raises ArgumentError when title is blank" do
    assert_raises(ArgumentError) { DS::EmptyState.new(title: nil) }
    assert_raises(ArgumentError) { DS::EmptyState.new(title: "") }
    assert_raises(ArgumentError) { DS::EmptyState.new(title: "  ") }
  end

  test "filled icon style wraps icon in a surface-inset disc" do
    render_inline(DS::EmptyState.new(title: "Empty", icon: "target", icon_style: :filled))

    assert_selector "div.bg-surface-inset.rounded-full svg"
  end

  test "plain icon style omits the disc wrapper" do
    render_inline(DS::EmptyState.new(title: "Empty", icon: "target", icon_style: :plain))

    assert_no_selector "div.bg-surface-inset"
    assert_selector "svg"
  end

  test "size :sm renders text-sm title and dense padding" do
    render_inline(DS::EmptyState.new(title: "Empty", size: :sm))

    assert_selector "h3.text-sm"
    assert_selector "div.py-10.px-4"
  end

  test "size :md renders text-lg title" do
    render_inline(DS::EmptyState.new(title: "Empty", size: :md))

    assert_selector "h3.text-lg"
  end

  test "size :lg renders text-xl title and tall padding" do
    render_inline(DS::EmptyState.new(title: "Empty", size: :lg))

    assert_selector "h3.text-xl"
    assert_selector "div.py-20.px-6"
  end

  test "yields a centered action area for caller-supplied content" do
    render_inline(DS::EmptyState.new(title: "Empty", description: "Body")) do
      '<a href="/new" class="action-link">New thing</a>'.html_safe
    end

    assert_selector "div.flex.flex-wrap.justify-center a.action-link", text: "New thing"
  end

  test "omits the action area when no block is given" do
    render_inline(DS::EmptyState.new(title: "Empty"))

    assert_no_selector "div.flex.flex-wrap.justify-center"
  end
end
