require "test_helper"

class DS::StatTest < ViewComponent::TestCase
  test "renders the label, the figure and the hint in that order" do
    render_inline(DS::Stat.new(label: "Chance the money lasts", value: "94%", hint: "Out of 5,000 runs"))

    texts = page.all("p").map(&:text)
    assert_equal [ "Chance the money lasts", "94%", "Out of 5,000 runs" ], texts
    assert_selector "p.text-2xl.font-medium.tabular-nums.text-primary", text: "94%"
    assert_selector "p.text-xs.text-subdued", text: "Out of 5,000 runs"
  end

  test "leaves the hint out when there is none" do
    render_inline(DS::Stat.new(label: "Stress", value: "35%"))

    assert_equal 2, page.all("p").size
  end

  test "takes a larger size and a tone, and falls back for unknown ones" do
    render_inline(DS::Stat.new(label: "FI number", value: "$1,050,000", size: :xl, tone: :success))
    assert_selector "p.text-3xl.text-success", text: "$1,050,000"

    render_inline(DS::Stat.new(label: "FI number", value: "$1", size: :huge, tone: :neon))
    assert_selector "p.text-2xl.text-primary", text: "$1"
  end

  test "passes extra classes and attributes to the figure, and options to the wrapper" do
    render_inline(DS::Stat.new(label: "FI number", value: "$1", value_class: "privacy-sensitive",
                               value_opts: { data: { fi_number: true } }, id: "fi", class: "mt-2"))

    assert_selector "div#fi.mt-2 p.privacy-sensitive[data-fi-number]", text: "$1"
  end

  test "a class in value_opts adds to the figure's classes rather than replacing them" do
    render_inline(DS::Stat.new(label: "FI number", value: "$1", value_class: "privacy-sensitive", value_opts: { class: "mt-1" }))

    assert_selector "p.text-2xl.font-medium.tabular-nums.text-primary.privacy-sensitive.mt-1", text: "$1"
  end

  test "a hint can take its own classes, such as privacy-sensitive" do
    render_inline(DS::Stat.new(label: "FI number", value: "$1", hint: "$42,000 a year", hint_class: "privacy-sensitive"))

    assert_selector "p.text-xs.text-subdued.privacy-sensitive", text: "$42,000 a year"
  end

  test "renders a value slot as given, in place of the figure" do
    render_inline(DS::Stat.new(label: "Earliest year")) do |stat|
      stat.with_value { "<p class='text-sm text-warning' data-none>None before 90</p>".html_safe }
    end

    assert_selector "p[data-none]", text: "None before 90"
    assert_no_selector "p.tabular-nums"
  end
end
