require "test_helper"

class DS::LogoTest < ViewComponent::TestCase
  DS::Logo::SIZES.each do |size, dimensions|
    [ nil, "", "https://cdn.brandfetch.io/wise.com?c=test" ].each do |src|
      test "#{size} logo with #{src.inspect} keeps correctly sized initials underneath" do
        render_inline DS::Logo.new(src: src, name: "Wise EUR", size: size, text_length: 2)

        assert_selector "span.relative.overflow-hidden[aria-hidden=true]", class: dimensions.split
        assert_selector ".absolute.inset-0", text: "Wi"
        assert_no_selector "[hidden], [data-controller]", visible: :all
        if src.present?
          assert_selector "img[alt=''][loading='lazy'][onerror='this.remove()'].absolute.bg-container", count: 1
          assert_selector "img.border.border-secondary"
        else
          assert_no_selector "img"
        end
      end
    end
  end

  test "preserves the fallback color and supplementary layout classes" do
    render_inline DS::Logo.new(src: nil, name: "Wise", color: "#123456", class_name: "mr-2")
    assert_selector "span.mr-2 [style*='#123456']", text: "W"
    assert_no_selector "span.border-secondary"
  end
end
