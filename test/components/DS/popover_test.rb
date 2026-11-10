require "test_helper"

class DS::PopoverTest < ViewComponent::TestCase
  test "renders the custom content inside the panel" do
    render_inline(DS::Popover.new(variant: "button")) do |popover|
      popover.with_button(text: "Open")
      popover.with_custom_content { "Panel body" }
    end

    assert_selector "[data-controller='DS--popover']"
    assert_selector "[data-ds--popover-target='content']", text: "Panel body", visible: :all
    assert_no_selector "[data-ds--popover-target='frame']", visible: :all
    assert_no_selector "[data-ds--popover-frame-src-value]"
  end

  test "a lazy frame panel ships an empty slot and the frame details for the controller" do
    render_inline(DS::Popover.new(variant: "button", frame_id: "tag_dropdown", frame_src: "/tag/dropdown?entry_id=1")) do |popover|
      popover.with_button(text: "Open")
    end

    assert_selector "[data-controller='DS--popover'][data-ds--popover-frame-id-value='tag_dropdown'][data-ds--popover-frame-src-value='/tag/dropdown?entry_id=1']"
    assert_selector "[data-ds--popover-target='frame']", visible: :all
    assert_no_selector "turbo-frame", visible: :all
  end

  test "frame id and src must come together" do
    error = assert_raises(ArgumentError) { DS::Popover.new(frame_id: "tag_dropdown") }
    assert_match(/frame_id and frame_src/, error.message)
    error = assert_raises(ArgumentError) { DS::Popover.new(frame_src: "/tag/dropdown") }
    assert_match(/frame_id and frame_src/, error.message)
  end
end
