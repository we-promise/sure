require "application_system_test_case"

# Below hotwire_combobox's `mobile_at` breakpoint (640px) the security search
# opens as a full-screen <dialog>. The gem paints that dialog with fixed light
# colors, so in the dark theme its label was dark text on a dark background and
# its input a bright white box, and the highlighted result was a light gray
# row with white text. Only a browser's computed styles show this.
class ComboboxMobileDialogTest < ApplicationSystemTestCase
  PHONE = [ 400, 850 ].freeze

  setup do
    @user = users(:family_admin)
    @user.update!(theme: "dark", show_sidebar: false, show_ai_sidebar: false)
    sign_in @user

    # The trade form only renders the security combobox when a provider exists.
    Security.stubs(:providers).returns([ mock("security_provider") ])
    Security.stubs(:search_provider).returns([ securities(:aapl), securities(:msft) ])

    page.driver.browser.manage.window.resize_to(*PHONE)
  end

  test "security search dialog uses theme colors in the dark theme" do
    visit new_trade_path(account_id: accounts(:investment).id)
    assert_selector "html[data-theme='dark']"

    find(".hw-combobox__input").click
    dialog = find("dialog.hw-combobox__dialog[open]")

    assert_equal element_style("bg-container", "backgroundColor"), computed(dialog, "backgroundColor")
    assert_equal element_style("text-primary", "color"), computed(dialog.find(".hw-combobox__dialog__label"), "color")

    input = dialog.find(".hw-combobox__dialog__input")
    assert_equal element_style("bg-container", "backgroundColor"), computed(input, "backgroundColor")
    assert_equal element_style("text-primary", "color"), computed(input, "color")

    # The gem highlights the active result with a fixed light gray, which left
    # white result text unreadable in the dark theme.
    input.send_keys("a")
    active = dialog.find(".hw-combobox__option--selected")
    assert_equal token_color("--color-container-inset-hover"), computed(active, "backgroundColor")
    assert_equal token_color("--color-container"),
      computed(dialog.find(".hw-combobox__option:not(.hw-combobox__option--selected)"), "backgroundColor")
  end

  private

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
