require "application_system_test_case"

class MfaVerifyTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_member)
    @user.setup_mfa!
    @backup_code = @user.enable_mfa!.first

    visit new_session_path
    within %(form[action='#{sessions_path}']) do
      find("input[type='email']").set(@user.email)
      find("input[type='password']").set(user_password_test)
      find("[type='submit']").click
    end
    assert_selector code_form
  end

  test "the code form submits once, and its button comes back with the page" do
    wait_for_loading_button

    # Hold the page in place so the state after a submit can be read; the
    # controller's own submit action still runs.
    page.execute_script(<<~JS)
      window.submitCount = 0
      document.querySelector("#{code_form}").addEventListener("submit", (event) => {
        window.submitCount++
        event.preventDefault()
      })
    JS

    # Labels as the browser rendered them: its locale need not be the test's.
    label = find(submit_button).text
    loading_label = find(code_form)["data-loading-button-loading-text-value"]
    assert_not_equal label, loading_label

    field = find("#{code_form} input[name='code']")
    field.set("123456")
    field.send_keys(:enter)

    assert_selector "#{submit_button}[disabled][aria-busy='true']", exact_text: loading_label

    # A second Enter, and a click on the disabled button, submit nothing.
    field.send_keys(:enter)
    page.execute_script(%(document.querySelector("#{submit_button}").click()))
    assert_equal 1, page.evaluate_script("window.submitCount")

    # What the browser fires when it restores the page from its back/forward cache.
    page.execute_script(%(window.dispatchEvent(new PageTransitionEvent("pageshow", { persisted: true }))))

    assert_selector "#{submit_button}:not([disabled]):not([aria-busy])", exact_text: label
  end

  test "a valid code signs in" do
    # A backup code, so a slow run cannot outlive the code it typed.
    field = find("#{code_form} input[name='code']")
    field.set(@backup_code)
    field.send_keys(:enter)

    assert_selector "h1", text: @user.first_name
  end

  private

    def code_form
      "form[action='#{verify_mfa_path}']"
    end

    def submit_button
      "#{code_form} button[type='submit']"
    end

    # The form is in the page before Stimulus has connected its controller.
    def wait_for_loading_button
      page.document.synchronize do
        connected = page.evaluate_script(<<~JS)
          (() => {
            const form = document.querySelector("#{code_form}");
            return !!form && !!window.Stimulus.getControllerForElementAndIdentifier(form, "loading-button");
          })()
        JS
        raise Capybara::ExpectationNotMet, "loading-button is not connected" unless connected
      end
    end
end
