require "application_system_test_case"

class TransactionTimestampsSystemTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

  setup do
    travel_to Time.utc(2026, 9, 22, 12)
    @user = users(:family_admin)
    @user.family.update!(timezone: "Europe/Paris")
    sign_in @user
  end

  test "CSV detection previews the date policy and imports exact times" do
    import = @user.family.imports.create!(type: "TransactionImport", account: accounts(:depository), date_format: "auto",
      raw_file_str: "\uFEFF\"Datetime\",\"Amount\",\"Merchant\"\n\"2026-09-17T23:30:12.123456Z\",-2.80,\"Synthetic cafe\"\n")
    visit import_configuration_path(import)
    select "Datetime", from: "import[date_col_label]"
    assert_text "One supported date/time format matches all nonblank values"
    assert_text "accounting date 2026-09-17"

    select "Use my Sure timezone (Europe/Paris)", from: "import[date_basis]"
    assert_text "accounting date 2026-09-18"
    assert_text "2026-09-18T01:30:12+02:00"
    select "Amount", from: "import[amount_col_label]"
    select "Merchant", from: "import[name_col_label]"
    click_on "Apply configuration"
    assert_text "Clean your data"
    click_on "Next step"
    assert_text "Assign your categories"
    click_on "Next"
    assert_text "Assign your tags"
    click_on "Next"
    assert_text "Confirm your import data"
    click_on "Publish import"
    assert_text "Import in progress"
    perform_enqueued_jobs(only: ImportJob)
    visit import_path(import)
    assert_text "Import successful"

    entry = import.entries.find_by!(name: "Synthetic cafe")
    assert_equal Date.new(2026, 9, 18), entry.date
    assert_equal Time.iso8601("2026-09-17T23:30:12.123456Z"), entry.transacted_at
  end

  test "ambiguous dates require a format choice in the browser" do
    import = @user.family.imports.create!(type: "TransactionImport", account: accounts(:depository), date_format: "auto",
      raw_file_str: "Date,Amount\n03/04/2026,12\n")
    visit import_configuration_path(import)
    select "Date", from: "import[date_col_label]"
    assert_text "The date/time format is ambiguous"
    select "Amount", from: "import[amount_col_label]"
    click_on "Apply configuration"
    assert_text "Date format The date/time format is ambiguous"
    assert_equal 0, import.rows.count

    select "DD/MM/YYYY (2026-04-03)", from: "import[date_format]"
    assert_text "accounting date 2026-04-03"
    click_on "Apply configuration"
    assert_text "Clean your data"
    assert_equal "2026-04-03", import.reload.rows.first.date_iso
  end

  test "manual timestamp editing and clearing work in the transaction drawer" do
    entry = entries(:transaction)
    entry.update!(transacted_at: Time.iso8601("2026-09-17T14:48:50.123456Z"))
    visit transactions_path
    click_link entry.name, exact: true
    find("summary", text: /\ADetails\z/i).click
    field = find("input[name='entry[transacted_at_local]']")
    assert_equal "2026-09-17T16:48:50", field.value
    # Capybara's native datetime setter formats Time values only to minutes.
    # Set the browser's native value and fire its change event to exercise seconds.
    field.execute_script("this.value = arguments[0]; this.dispatchEvent(new Event('change', { bubbles: true }));", "2026-09-17T17:12:34")
    name_link = find("##{dom_id(entry)} a[data-clickable-row-target='link']", visible: :all)
    assert_no_selector "##{dom_id(entry)} a[data-clickable-row-target='link'][title]", visible: :all
    assert_selector "##{dom_id(entry)} [data-controller='DS--tooltip']:has(a[data-clickable-row-target='link']) [role='tooltip']",
      text: "2026-09-17T17:12:34+02:00", visible: :all
    find("dialog[open] button[aria-label='Close']").click
    name_link = find("##{dom_id(entry)} a[data-clickable-row-target='link']")
    name_link.hover
    assert_selector "##{dom_id(entry)} [data-controller='DS--tooltip']:has(a[data-clickable-row-target='link']) [role='tooltip']:not(.hidden)",
      text: "2026-09-17T17:12:34+02:00"
    name_link.execute_script("this.blur()")
    find("h1", text: "Transactions").hover
    assert_selector "##{dom_id(entry)} [role='tooltip'].hidden", visible: :all
    name_link.execute_script("this.focus()")
    assert_selector "##{dom_id(entry)} [data-controller='DS--tooltip']:has(a[data-clickable-row-target='link']) [role='tooltip']:not(.hidden)",
      text: "2026-09-17T17:12:34+02:00"
    assert_equal Time.utc(2026, 9, 17, 15, 12, 34), entry.reload.transacted_at

    click_link entry.name, exact: true
    find("summary", text: /\ADetails\z/i).click
    field = find("input[name='entry[transacted_at_local]']")
    field.execute_script("this.value = ''; this.dispatchEvent(new Event('change', { bubbles: true }));")
    assert_no_selector "##{dom_id(entry)} [data-controller='DS--tooltip']:has(a[data-clickable-row-target='link'])", visible: :all
    assert_nil entry.reload.transacted_at
  end

  test "the transaction list uses edited timestamps when refreshed" do
    account = accounts(:depository)
    early = account.entries.create!(name: "Timestamp order early", date: "2026-09-17", amount: 1, currency: "USD",
      transacted_at: Time.utc(2026, 9, 17, 9), entryable: Transaction.new)
    late = account.entries.create!(name: "Timestamp order late", date: "2026-09-17", amount: 2, currency: "USD",
      transacted_at: Time.utc(2026, 9, 17, 16), entryable: Transaction.new)
    visit transactions_path(q: { search: "Timestamp order" })
    assert_selector "##{dom_id(late)} + ##{dom_id(early)}"

    click_link early.name, exact: true
    find("summary", text: /\ADetails\z/i).click
    find("input[name='entry[transacted_at_local]']").execute_script(
      "this.value = arguments[0]; this.dispatchEvent(new Event('change', { bubbles: true }));", "2026-09-17T20:00:00")
    assert_selector "##{dom_id(early)} [data-controller='DS--tooltip']:has(a[data-clickable-row-target='link']) [role='tooltip']",
      text: "2026-09-17T20:00:00+02:00", visible: :all
    find("dialog[open] button[aria-label='Close']").click
    refresh
    assert_selector "##{dom_id(early)} + ##{dom_id(late)}"
  end
end
