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
end
