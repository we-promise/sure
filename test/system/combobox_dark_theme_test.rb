require "application_system_test_case"

# Below hotwire_combobox's `mobile_at` breakpoint (640px) the security search
# opens as a full-screen <dialog>. The gem paints that dialog with fixed light
# colors, so in the dark theme its label was dark text on a dark background and
# its input a bright white box, and the hovered result was a light gray
# row with white text. The hover highlight was just as unreadable in the
# desktop dropdown. Only a browser's computed styles show this.
class ComboboxDarkThemeTest < ApplicationSystemTestCase
  PHONE = [ 400, 850 ].freeze

  setup do
    @user = users(:family_admin)
    @user.update!(theme: "dark", show_sidebar: false, show_ai_sidebar: false)
    sign_in @user

    # The trade form only renders the security combobox when a provider exists.
    Security.stubs(:providers).returns([ mock("security_provider") ])
    Security.stubs(:search_provider).returns([ securities(:aapl), securities(:msft) ])
  end

  test "security search dialog uses theme colors in the dark theme" do
    page.driver.browser.manage.window.resize_to(*PHONE)
    visit new_trade_path(account_id: accounts(:investment).id)
    assert_selector "html[data-theme='dark']"

    find(".hw-combobox__input").click
    dialog = find("dialog.hw-combobox__dialog[open]")

    assert_equal element_style("bg-container", "backgroundColor"), computed(dialog, "backgroundColor")
    assert_equal element_style("text-primary", "color"), computed(dialog.find(".hw-combobox__dialog__label"), "color")

    input = dialog.find(".hw-combobox__dialog__input")
    assert_equal element_style("bg-container", "backgroundColor"), computed(input, "backgroundColor")
    assert_equal element_style("text-primary", "color"), computed(input, "color")

    # The gem highlights a hovered result with a fixed light gray, which left
    # white result text unreadable in the dark theme.
    input.send_keys("a")
    assert_hover_uses_theme_colors(dialog)
  end

  # Above the breakpoint the results open in an inline dropdown, whose hovered
  # result reads the same gem variable.
  test "desktop security dropdown uses theme colors in the dark theme" do
    visit new_trade_path(account_id: accounts(:investment).id)
    assert_selector "html[data-theme='dark']"

    find(".hw-combobox__input").send_keys("a")
    listbox = find(".hw-combobox__listbox", visible: true)
    assert_no_selector "dialog.hw-combobox__dialog[open]"

    assert_hover_uses_theme_colors(listbox)
  end

  private

    # Hovers one result and checks it against another, untouched one. Results
    # are found by name each time because the async search re-renders them.
    def assert_hover_uses_theme_colors(container)
      option = ->(name) { container.find(".hw-combobox__option", text: name) }
      option.call("Microsoft")
      option.call("Apple").hover

      assert_equal token_color("--color-container-inset-hover"), computed(option.call("Apple"), "backgroundColor")
      assert_equal element_style("text-primary", "color"), computed(option.call("Apple"), "color")
      assert_equal token_color("--color-container"), computed(option.call("Microsoft"), "backgroundColor")
    end

    # What `element` computes for the CSS `property`.
    def computed(element, property)
      element.evaluate_script("getComputedStyle(this)[#{property.to_json}]")
    end

    # The background color a design-system color variable resolves to.
    def token_color(variable)
      page.evaluate_script(<<~JS)
        (() => {
          const probe = document.body.appendChild(document.createElement("div"));
          probe.style.backgroundColor = "var(#{variable})";
          const value = getComputedStyle(probe).backgroundColor;
          probe.remove();
          return value;
        })()
      JS
    end

    # What an element with `class_name` computes for `property`.
    def element_style(class_name, property)
      page.evaluate_script(<<~JS)
        (() => {
          const probe = document.body.appendChild(document.createElement("div"));
          probe.className = #{class_name.to_json};
          const value = getComputedStyle(probe)[#{property.to_json}];
          probe.remove();
          return value;
        })()
      JS
    end
end
