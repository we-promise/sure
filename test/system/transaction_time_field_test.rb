require "application_system_test_case"

class TransactionTimeFieldTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
  end

  test "editing the time field does not close the drawer and can be cleared" do
    transaction = transactions(:one)
    entry = transaction.entry
    entry.update!(time: "09:15")

    visit transactions_url

    page.execute_script <<~JS
      const frame = document.querySelector("turbo-frame#drawer")
      frame.src = "#{transaction_url(entry)}"
    JS

    within "turbo-frame#drawer", visible: :all do
      assert_selector "dialog[open]"

      time_field = find_field("Time")
      assert_equal "09:15", time_field.value

      # Rapid changes shouldn't submit the field until it loses focus.
      time_field.click
      5.times { time_field.send_keys(:up) }
      assert_selector "dialog[open]"

      find("button[aria-label='Clear time']").click
    end

    within "##{ActionView::RecordIdentifier.dom_id(entry, :header)}" do
      assert_no_text(/\d{1,2}:\d{2}\s*[AP]M/)
    end

    assert_nil entry.reload.time
    assert_selector "turbo-frame#drawer dialog[open]", visible: :all
  end
end
