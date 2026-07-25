require "test_helper"

class DS::DisclosureTest < ViewComponent::TestCase
  test "bare variant yields panel content without mt-2 wrapper" do
    render_inline(DS::Disclosure.new(variant: :bare, summary_class: "cursor-pointer")) do |disclosure|
      disclosure.with_summary_content { "Toggle" }
      "Panel"
    end

    assert page.has_css?("details.group")
    assert page.has_text?("Panel")
    assert_no_match(/<div class="mt-2">/, rendered_content)
  end

  test "body wrapper defaults to an mt-2 margin" do
    render_inline(DS::Disclosure.new(title: "More", open: true)) { "body text" }

    assert_selector "details > div.mt-2", text: "body text"
  end

  test "body_class: nil drops the body margin wrapper" do
    render_inline(DS::Disclosure.new(title: "More", open: true, body_class: nil)) { "body text" }

    assert_no_selector "details > div.mt-2"
    assert_selector "details > div", text: "body text"
  end

  test "forwards data attributes and a summary_class override" do
    render_inline(DS::Disclosure.new(
      summary_class: "custom-summary",
      data: { controller: "color-icon-picker", action: "mousedown->color-icon-picker#handleOutsideClick" }
    )) do |disclosure|
      disclosure.with_summary_content { "trigger" }
    end

    assert_selector "details[data-controller='color-icon-picker']"
    assert_selector "summary.custom-summary", text: "trigger"
  end
end
