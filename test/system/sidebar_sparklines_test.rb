require "application_system_test_case"

# The sidebar sparkline frames are data-turbo-permanent and carry a data
# version in their id. A loaded sparkline must survive navigations and morph
# refreshes while its data is unchanged, and must be replaced by a fresh frame
# once the data changes. Idiomorph never removes permanent elements on its
# own; permanent_frame_controller.js releases the stale frame on a morph.
class SidebarSparklinesTest < ApplicationSystemTestCase
  FRAME_SELECTOR = "turbo-frame[id^='tab_'][id*='_sparkline_'][complete]".freeze

  setup do
    @user = users(:family_admin)
    sign_in @user
  end

  test "a loaded sparkline frame is kept while its data is unchanged" do
    visit root_path
    frame_id = mark_loaded_sparkline

    find("a[href='#{transactions_path}']", match: :first).click
    assert_current_path transactions_path
    assert_marked_frame frame_id

    refresh_with_morph
    assert_marked_frame frame_id
  end

  test "a morph refresh replaces a sparkline frame whose data changed" do
    visit root_path
    frame_id = mark_loaded_sparkline

    # Any account update moves the sparkline data version, as a completed
    # sync does.
    @user.family.accounts.first.touch

    refresh_with_morph

    assert_no_selector "##{frame_id}", visible: :all
    assert_selector FRAME_SELECTOR, visible: :all
    assert_no_selector "#{FRAME_SELECTOR}[data-test-marker]", visible: :all
  end

  private
    # Waits for a sidebar sparkline to finish loading and tags that element, so
    # a later check can tell the same DOM node apart from a re-rendered one.
    def mark_loaded_sparkline
      frame = find(FRAME_SELECTOR, match: :first, visible: :all)
      page.execute_script("arguments[0].setAttribute('data-test-marker', 'loaded')", frame)
      frame[:id]
    end

    def assert_marked_frame(frame_id)
      assert_selector "##{frame_id}[complete][data-test-marker='loaded']", visible: :all
    end

    # What a broadcast refresh (turbo_stream_from Current.family) does after a
    # sync completes: reload the current URL, rendered as a morph.
    def refresh_with_morph
      page.execute_script(<<~JS)
        document.documentElement.removeAttribute("data-test-refreshed")
        document.addEventListener("turbo:render", () => {
          document.documentElement.setAttribute("data-test-refreshed", "true")
        }, { once: true })
        Turbo.session.refresh(window.location.href)
      JS
      assert_selector "html[data-test-refreshed='true']", visible: :all
    end
end
