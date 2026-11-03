require "application_system_test_case"

class TransactionsTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)

    Entry.delete_all # clean slate

    create_transaction("one", 12.days.ago.to_date, 100)
    create_transaction("two", 10.days.ago.to_date, 100)
    create_transaction("three", 9.days.ago.to_date, 100)
    create_transaction("four", 8.days.ago.to_date, 100)
    create_transaction("five", 7.days.ago.to_date, 100)
    create_transaction("six", 7.days.ago.to_date, 100)
    create_transaction("seven", 4.days.ago.to_date, 100)
    create_transaction("eight", 3.days.ago.to_date, 100)
    create_transaction("nine", 1.days.ago.to_date, 100)
    @uncategorized_transaction = create_transaction("ten", 1.days.ago.to_date, 100)
    create_transaction("eleven", Date.current, 100, category: categories(:food_and_drink), tags: [ tags(:one) ], merchant: merchants(:amazon))

    @transactions = @user.family.entries
                         .transactions
                         .reverse_chronological

    @transaction = @transactions.first

    @page_size = 10

    visit transactions_url(per_page: @page_size)
  end

  test "can search for a transaction" do
    assert_selector "h1", text: "Transactions"

    within "form#transactions-search" do
      fill_in "Search transactions ...", with: @transaction.name
      find("#q_search").send_keys(:tab) # Trigger blur to submit form
    end

    assert_selector "#" + dom_id(@transaction), count: 1

    within "#transaction-search-filters" do
      assert_text @transaction.name
    end
  end

  test "can open filters and apply one or more" do
    find("#transaction-filters-button").click

    within "#transaction-filters-menu" do
      check(@transaction.account.name)
      click_button "Category"
      check(@transaction.transaction.category.name)
      click_button "Apply"
    end

    assert_selector "#" + dom_id(@transaction), count: 1

    within "#transaction-search-filters" do
      assert_text @transaction.account.name
      assert_text @transaction.transaction.category.name
    end
  end

  test "can filter uncategorized transactions" do
    find("#transaction-filters-button").click

    within "#transaction-filters-menu" do
      click_button "Category"
      check("Uncategorized")
      click_button "Apply"
    end

    assert_selector "#" + dom_id(@uncategorized_transaction), count: 1
    assert_no_selector("#" + dom_id(@transaction))

    find("#transaction-filters-button").click

    within "#transaction-filters-menu" do
      click_button "Category"
      check(@transaction.transaction.category.name)
      click_button "Apply"
    end

    assert_selector "#" + dom_id(@transaction), count: 1
    assert_selector "#" + dom_id(@uncategorized_transaction), count: 1
  end

  test "all filters work and empty state shows if no match" do
    find("#transaction-filters-button").click

    account = @transaction.account
    category = @transaction.transaction.category
    merchant = @transaction.transaction.merchant

    within "#transaction-filters-menu" do
      click_button "Account"
      check(account.name)

      click_button "Date"
      fill_in "q_start_date", with: 10.days.ago.to_date
      fill_in "q_end_date", with: 1.day.ago.to_date

      click_button "Type"
      check("Income")

      click_button "Amount"
      select "Less than"
      fill_in "q_amount", with: 200

      click_button "Category"
      check(category.name)

      click_button "Merchant"
      check(merchant.name)

      click_button "Apply"
    end

    assert_text "No entries found"

    # Wait for Turbo to finish updating the DOM
    sleep 0.5

    # Page reload doesn't affect results
    visit current_url

    assert_text "No entries found"

    # Remove all filters by clicking their X buttons
    # Get all the filter buttons at once to avoid stale elements
    filter_count = page.all("ul#transaction-search-filters li button").count

    # Click each one with a small delay to let Turbo update
    filter_count.times do
      page.all("ul#transaction-search-filters li button").first.click
      sleep 0.1
    end

    assert_text @transaction.name
  end

  test "confirms an auto-matched transfer from beside the amount" do
    outflow = create_transaction("Payment to credit card", Date.current, 100)
    inflow = create_transaction("Payment received", Date.current, -100, account: accounts(:credit_card))
    transfer = Transfer.create!(outflow_transaction: outflow.entryable, inflow_transaction: inflow.entryable)
    match = "##{dom_id(outflow.entryable, :transfer_match)}"
    visit transactions_url(per_page: @page_size)

    assert_selector match
    assert_no_selector "[data-tag-fit-bounds='0.5'] #{match}"

    within(match) { click_button I18n.t("transactions.transfer_match.confirm_match") }

    assert_no_selector "#{match} button"
    assert transfer.reload.confirmed?

    page.current_window.resize_to(390, 900)
    visit transactions_url(per_page: @page_size)
    indicator_bounds = find(match).evaluate_script("this.getBoundingClientRect().toJSON()")
    amount_bounds = find("##{dom_id(outflow)} p.privacy-sensitive").evaluate_script("this.getBoundingClientRect().toJSON()")
    assert_in_delta indicator_bounds["y"] + indicator_bounds["height"] / 2,
                    amount_bounds["y"] + amount_bounds["height"] / 2, 1,
                    "confirmed matches should stay beside the amount on phones"
  end

  test "rejects an auto-matched transfer from a mobile row" do
    outflow = create_transaction("Payment to credit card", Date.current, 100)
    inflow = create_transaction("Payment received", Date.current, -100, account: accounts(:credit_card))
    transfer = Transfer.create!(outflow_transaction: outflow.entryable, inflow_transaction: inflow.entryable)
    match = "##{dom_id(outflow.entryable, :transfer_match)}"
    page.current_window.resize_to(390, 900)
    visit transactions_url(per_page: @page_size)

    within(match) do
      assert_text I18n.t("transactions.transfer_match.auto_matched_short")
      assert_selector "button[aria-label='#{I18n.t("transactions.transfer_match.confirm_match")}']"
      click_button I18n.t("transactions.transfer_match.reject_match")
    end

    assert_no_selector match
    assert_not Transfer.exists?(transfer.id)
    assert Entry.exists?(outflow.id)
    assert Entry.exists?(inflow.id)
  end

  test "keeps long auto-matched tablet and desktop rows contained" do
    @user.update!(show_ai_sidebar: false)
    outflow = create_transaction("Bank of America online payment with a long bank descriptor", Date.current, 4321.09, tags: [ tags(:one), tags(:two) ])
    inflow = create_transaction("Payment received", Date.current, -4321.09, account: accounts(:credit_card))
    Transfer.create!(outflow_transaction: outflow.entryable, inflow_transaction: inflow.entryable)
    outflow.entryable.update!(kind: "funds_movement", extra: { "plaid" => { "pending" => true }, "potential_posted_match" => { "entry_id" => inflow.id, "confidence" => "low" } })
    [ 820, 1024, 1440 ].each do |width|
      page.current_window.resize_to(width, 900)
      visit transactions_url(per_page: @page_size)

      row = find("##{dom_id(outflow)} [data-controller='clickable-row']")
      row_bounds = row.evaluate_script("this.getBoundingClientRect().toJSON()")
      amount_bounds = row.find("p.privacy-sensitive").evaluate_script("this.getBoundingClientRect().toJSON()")
      tags_bounds = row.find("[id^='tag_summary_desktop']").evaluate_script("this.getBoundingClientRect().toJSON()")
      match_bounds = row.find("[id^='transfer_match']").evaluate_script("this.getBoundingClientRect().toJSON()")
      controls_bounds = row.find("[data-tag-fit-bounds='1']").find(:xpath, "..").evaluate_script("this.getBoundingClientRect().toJSON()")

      assert_operator match_bounds["left"], :>=, controls_bounds["left"], "matching controls must not spill into the category at #{width}px"
      assert_operator match_bounds["right"], :<=, controls_bounds["right"]

      assert_operator amount_bounds["right"], :<=, row_bounds["right"]
      assert_operator amount_bounds["left"], :>=, row_bounds["left"]
      assert_operator amount_bounds["height"], :<=, 24, "the amount should stay on one line at #{width}px"
      assert tags_bounds["right"] <= match_bounds["left"] || tags_bounds["bottom"] <= match_bounds["top"],
             "tags and matching controls must not overlap at #{width}px"
    end
  end

  test "can toggle tags from the transaction row" do
    transaction = @transaction.entryable
    summary_id = dom_id(transaction, "tag_summary_desktop")
    option_id = "#{dom_id(@transaction, :tag_option)}_#{tags(:two).id}"

    within "##{summary_id}" do
      assert_text tags(:one).name
    end

    find("##{summary_id}").click
    find("##{option_id} button").click

    assert_selector "##{option_id}[aria-selected='true']"
    assert_selector "##{summary_id} [data-tag-fit-target=compact] [data-tag-initial]", count: 2, visible: :all
    assert_equal [ tags(:one).id, tags(:two).id ].sort, transaction.reload.tag_ids.sort
  end

  test "tags show as full pills when they fit and collapse when the column shrinks" do
    transaction = @transaction.entryable
    short_tags = %w[Ab Cd].map { |name| @user.family.tags.create!(name: name, color: Tag::COLORS.first) }
    transaction.update!(tag_ids: short_tags.map(&:id))
    visit transactions_url(per_page: @page_size)

    summary = "##{dom_id(transaction, "tag_summary_desktop")}"
    cell = "document.querySelector('#{summary}').closest('[data-tag-fit-bounds]')"

    # Control the actual available width even when the tag cell is a flex item.
    page.execute_script("#{cell}.style.flex = 'none'")
    page.execute_script("#{cell}.style.width = '400px'")
    assert_selector "#{summary} [data-tag-fit-target=full]", text: "Ab"
    assert_no_selector "#{summary} [data-tag-fit-target=compact]"

    page.execute_script("#{cell}.style.width = '48px'")
    assert_selector "#{summary} [data-tag-fit-target=compact] [data-tag-initial]", count: 2
    assert_no_selector "#{summary} [data-tag-fit-target=full]"

    page.execute_script("#{cell}.style.width = '400px'")
    assert_selector "#{summary} [data-tag-fit-target=full]", text: "Cd"
  end

  test "a first tag added on desktop also shows on the mobile row" do
    transaction = @uncategorized_transaction.entryable
    assert_empty transaction.tags
    option_id = "#{dom_id(@uncategorized_transaction, :tag_option)}_#{tags(:one).id}"

    find("##{dom_id(@uncategorized_transaction)}").hover
    find("##{dom_id(transaction, "tag_summary_desktop")}").click
    find("##{option_id} button").click
    assert_selector "##{option_id}[aria-selected='true']"

    page.current_window.resize_to(390, 900)
    assert_selector "##{dom_id(transaction, "tag_summary_mobile")}", text: tags(:one).name
  ensure
    page.current_window.resize_to(1400, 1400)
  end

  test "keyboard focus stays on a tag option after toggling it" do
    summary_id = dom_id(@transaction.entryable, "tag_summary_desktop")
    option_id = "#{dom_id(@transaction, :tag_option)}_#{tags(:two).id}"

    find("##{summary_id}").click
    button = find("##{option_id} button")
    button.send_keys(:enter)

    assert_selector "##{option_id}[aria-selected='true']"
    assert page.evaluate_script("document.activeElement.closest('##{option_id}') !== null"),
      "focus should remain on the toggled option"
  end

  test "can select and deselect entire page of transactions" do
    all_transactions_checkbox.check
    assert_selection_count(number_of_transactions_on_page)
    all_transactions_checkbox.uncheck
    assert_selection_count(0)
  end

  test "can select and deselect groups of transactions" do
    date_transactions_checkbox(1.day.ago.to_date).check
    assert_selection_count(2)

    date_transactions_checkbox(1.day.ago.to_date).uncheck
    assert_selection_count(0)
  end

  test "can select and deselect individual transactions" do
    transaction_checkbox(@transactions.first).check
    assert_selection_count(1)
    transaction_checkbox(@transactions.second).check
    assert_selection_count(2)
    transaction_checkbox(@transactions.second).uncheck
    assert_selection_count(1)
  end

  test "outermost group always overrides inner selections" do
    transaction_checkbox(@transactions.first).check
    assert_selection_count(1)

    all_transactions_checkbox.check
    assert_selection_count(number_of_transactions_on_page)

    transaction_checkbox(@transactions.first).uncheck
    assert_selection_count(number_of_transactions_on_page - 1)

    date_transactions_checkbox(1.day.ago.to_date).uncheck
    assert_selection_count(number_of_transactions_on_page - 3)

    all_transactions_checkbox.uncheck
    assert_selection_count(0)
  end


  test "can create deposit transaction for investment account" do
    investment_account = accounts(:investment)
    investment_account.entries.create!(name: "Investment account", date: Date.current, amount: 1000, currency: "USD", entryable: Transaction.new)
    transfer_date = Date.current
    visit account_url(investment_account, tab: "activity")
    within "[data-testid='activity-menu']" do
      click_on "New"
      click_on "New activity"
    end
    select "Deposit", from: "Type"
    fill_in "Date", with: transfer_date
    fill_in "model[amount]", with: 175.25
    click_button "Add transaction"
    within "#" + dom_id(investment_account, "entries_#{transfer_date}") do
      assert_text "175.25"
    end
  end

  test "transfers should always sum to zero" do
    # Use two accounts that result in funds_movement kind (not investment/crypto which become investment_contribution)
    asset_account = accounts(:other_asset)
    depository_account = accounts(:depository)
    outflow_entry = create_transaction("outflow", Date.current, 500, account: asset_account)
    inflow_entry = create_transaction("inflow", 1.day.ago.to_date, -500, account: depository_account)
    @user.family.auto_match_transfers!
    # Entry.delete_all in setup orphans the fixture transfer, so confirm only this one
    Transfer.find_by!(outflow_transaction_id: outflow_entry.entryable_id).confirm!
    visit transactions_url

    within "#entry-group-" + Date.current.to_s + "-totals" do
      assert_text "-$100.00" # transaction eleven from setup
    end
  end

  private

    def create_transaction(name, date, amount, category: nil, merchant: nil, tags: [], account: nil)
      account ||= accounts(:depository)

      account.entries.create! \
        name: name,
        date: date,
        amount: amount,
        currency: "USD",
        entryable: Transaction.new(category: category, merchant: merchant, tags: tags)
    end

    def number_of_transactions_on_page
      [ @user.family.entries.count, @page_size ].min
    end

    def all_transactions_checkbox
      find("#selection_entry")
    end

    def date_transactions_checkbox(date)
      find("#selection_entry_#{date}")
    end

    def transaction_checkbox(transaction)
      find("#" + dom_id(transaction, "selection"))
    end

    def assert_selection_count(count)
      if count == 0
        assert_no_selector("#entry-selection-bar")
      else
        within "#entry-selection-bar" do
          assert_text "#{count} transaction#{count == 1 ? "" : "s"} selected"
        end
      end
    end
end
