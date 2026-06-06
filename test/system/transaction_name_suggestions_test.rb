require "application_system_test_case"

class TransactionNameSuggestionsTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:depository)

    Entry.delete_all
    create_transaction("Coffee Roasters", 2.days.ago.to_date, 12.50)
  end

  test "selecting a suggestion notifies downstream input and change listeners" do
    visit new_transaction_path

    find("input[name='entry[name]']")
    page.execute_script(<<~JS)
      window.transactionNameSuggestionEvents = [];
      const input = document.querySelector("input[name='entry[name]']");
      ["input", "change"].forEach((type) => {
        input.addEventListener(type, (event) => {
          window.transactionNameSuggestionEvents.push({
            type: event.type,
            value: event.target.value
          });
        });
      });
    JS

    fill_in "Description", with: "Coffee"
    find("[role='option']", text: "Coffee Roasters").click

    events = page.evaluate_script("window.transactionNameSuggestionEvents")
    assert_includes events, { "type" => "input", "value" => "Coffee Roasters" }
    assert_includes events, { "type" => "change", "value" => "Coffee Roasters" }
  end

  private

    def create_transaction(name, date, amount)
      @account.entries.create!(
        name: name,
        date: date,
        amount: amount,
        currency: "USD",
        entryable: Transaction.new
      )
    end
end
