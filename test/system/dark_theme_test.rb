require "application_system_test_case"

# Dark theme values have to reach pseudo-elements as well as elements, which
# only a browser's computed styles can show.
class DarkThemeTest < ApplicationSystemTestCase
  test "pseudo-element variants take the dark theme values" do
    user = users(:family_admin)
    user.update!(theme: "dark")
    sign_in user
    visit transactions_url

    assert_equal element_style("text-secondary", "color"),
      find("#q_search").evaluate_script("getComputedStyle(this, '::placeholder').color")

    click_on "New transaction"
    assert_equal element_style("bg-overlay", "backgroundColor"),
      find("dialog[open]").evaluate_script("getComputedStyle(this, '::backdrop').backgroundColor")
  end

  private

    # What an element with `class_name` computes for `property`, which the same
    # utility under a pseudo-element variant has to match.
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
