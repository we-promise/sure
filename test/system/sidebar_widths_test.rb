require "application_system_test_case"

# The head script applies the stored sidebar widths before the first paint,
# and sidebar_resize_controller applies them again once it connects; wherever
# the two disagree, the sidebars visibly jump after the page appears.
class SidebarWidthsTest < ApplicationSystemTestCase
  setup do
    sign_in users(:family_admin)
  end

  test "without the assistant the left sidebar keeps the room of the right one the layout leaves out" do
    users(:family_admin).family.update!(assistant_type: "mcp_only")
    page.driver.browser.manage.window.resize_to(1280, 900)
    visit root_path
    page.execute_script(%(localStorage.setItem("sure.sidebarWidth.left", "480"); localStorage.setItem("sure.sidebarWidth.right", "560")))

    visit root_path

    assert_nil page.evaluate_script(%(document.querySelector("[data-app-layout-target='rightSidebar']"))), "the layout leaves the right sidebar out"
    assert_equal kept_widths.first, before_paint_widths.first
    assert_equal "480px", before_paint_widths.first, "the stored width fits once no room is kept for the right sidebar"
  ensure
    page.execute_script(%(localStorage.removeItem("sure.sidebarWidth.left"); localStorage.removeItem("sure.sidebarWidth.right")))
  end

  test "the widths applied before the first paint are the ones the resize controller keeps" do
    page.driver.browser.manage.window.resize_to(1280, 900)
    visit root_path
    # Wider together than the viewport allows with both sidebars open.
    page.execute_script(%(localStorage.setItem("sure.sidebarWidth.left", "480"); localStorage.setItem("sure.sidebarWidth.right", "560")))

    visit root_path

    assert page.evaluate_script(%(["leftSidebar", "rightSidebar"].every((target) => document.querySelector("[data-app-layout-target='" + target + "']").offsetWidth > 0))), "both sidebars open"
    before_paint = before_paint_widths
    kept = kept_widths

    assert_equal kept, before_paint
    assert_operator before_paint.sum(&:to_i), :<, 560 + 480, "the pair was not clamped together"
  ensure
    page.execute_script(%(localStorage.removeItem("sure.sidebarWidth.left"); localStorage.removeItem("sure.sidebarWidth.right")))
  end

  # A visit that leaves the head script unchanged doesn't run it again; a
  # window resized on a page without the sidebars (settings, where no resize
  # controller follows the window) must not bring the old window's widths back.
  test "a visit after a window resize on a page without the sidebars starts at widths that fit the window" do
    page.driver.browser.manage.window.resize_to(1600, 1000)
    visit root_path
    page.execute_script(%(localStorage.setItem("sure.sidebarWidth.left", "480"); localStorage.setItem("sure.sidebarWidth.right", "560")))
    visit settings_profile_path
    assert_no_selector "[data-controller~='sidebar-resize']", visible: :all
    page.driver.browser.manage.window.resize_to(1280, 900)

    page.execute_script(<<~JS)
      document.addEventListener("turbo:before-render", () => {
        const style = getComputedStyle(document.documentElement)
        window.widthsAtRender = ["left", "right"].map((side) => style.getPropertyValue("--" + side + "-sidebar-width").trim())
      }, { once: true })
      Turbo.visit("/")
    JS

    kept = kept_widths
    assert_not_equal %w[480px 560px], kept, "the narrower window clamps the pair"
    assert_equal kept, page.evaluate_script("window.widthsAtRender"), "the page rendered at the old window's widths"
  ensure
    page.execute_script(%(localStorage.removeItem("sure.sidebarWidth.left"); localStorage.removeItem("sure.sidebarWidth.right")))
  end

  test "a visit after a resize keeps the sidebar at its new width instead of sliding back to it" do
    page.driver.browser.manage.window.resize_to(1500, 1000)
    visit root_path
    find("[data-action*='sidebar-resize#keyLeft']").send_keys(:arrow_left, :arrow_left, :arrow_left)
    resized = page.evaluate_script(%(Math.round(document.querySelector("[data-app-layout-target='leftSidebar']").getBoundingClientRect().width)))
    assert_equal 320 - 3 * 16, resized
    assert_equal "#{resized}px", page.evaluate_script(%(getComputedStyle(document.documentElement).getPropertyValue("--left-sidebar-width").trim())),
      "a page swapped in by a visit reads the width from <html> until the resize controller connects"
    assert_equal "width", page.evaluate_script(%(getComputedStyle(document.querySelector("[data-app-layout-target='leftSidebar']")).transitionProperty)),
      "only opening and closing animate; a width set by a resize or a visit applies at once"
    find("#sidebar-scroll details", match: :first).find("summary").click

    # Every frame from the click until 600 ms after the destination rendered,
    # however long the visit takes; <html> (which a visit keeps) is marked
    # when sampling is done, so the test waits for that rather than sleeping.
    page.execute_script(<<~JS)
      window.sidebarWidths = []
      let renderedAt = null
      document.addEventListener("turbo:render", () => { renderedAt = performance.now() }, { once: true })
      const sample = (now) => {
        const width = Math.round(document.querySelector("[data-app-layout-target='leftSidebar']").getBoundingClientRect().width)
        window.sidebarWidths.push({ width: width, afterRender: renderedAt !== null })
        if (renderedAt === null || now - renderedAt < 600) requestAnimationFrame(sample)
        else document.documentElement.dataset.sidebarSampled = "true"
      }
      requestAnimationFrame(sample)
    JS
    find("#sidebar-scroll details[open] a[href^='/accounts/']", match: :first).click
    assert_selector "#sidebar-scroll a[data-active-account]"
    assert_selector "html[data-sidebar-sampled]", visible: :all, wait: 10

    samples = page.evaluate_script("window.sidebarWidths")
    assert samples.any? { |sample| sample["afterRender"] }, "no frame of the destination page was sampled"
    assert_equal [ resized ], samples.map { |sample| sample["width"] }.uniq, "the sidebar changed width across the visit"
  ensure
    page.execute_script(%(localStorage.removeItem("sure.sidebarWidth.left"); localStorage.removeItem("sure.sidebarWidth.right")))
  end

  private
    # The widths the inline head script sets before the first paint. Reading
    # them off <html> afterwards would see what sidebar_resize_controller
    # wrote there once it connected, so the page's own script is run again
    # against a stand-in document: same viewport, same stored widths.
    def before_paint_widths
      page.evaluate_script(<<~JS)
        (() => {
          const script = Array.from(document.head.querySelectorAll("script")).find((s) => s.textContent.includes("sure.sidebarWidth."))
          const set = {}
          new Function("document", script.textContent)({ documentElement: { style: { setProperty: (name, value) => { set[name] = value } } } })
          return ["left", "right"].map((side) => set["--" + side + "-sidebar-width"])
        })()
      JS
    end

    # What sidebar_resize_controller applied once it connected; it writes both
    # widths on connect, so wait for them rather than reading too early.
    def kept_widths
      assert_selector "[data-controller~='sidebar-resize'][style*='--left-sidebar-width'][style*='--right-sidebar-width']", visible: :all
      page.evaluate_script(%(["left", "right"].map((side) => document.querySelector("[data-controller~='sidebar-resize']").style.getPropertyValue("--" + side + "-sidebar-width"))))
    end
end
