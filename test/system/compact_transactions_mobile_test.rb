require "application_system_test_case"

class CompactTransactionsMobileTest < ApplicationSystemTestCase
  DEFAULT_VIEWPORT_WIDTH = 1400
  DEFAULT_VIEWPORT_HEIGHT = 1400

  setup do
    ensure_tailwind_build
    sign_in @user = users(:family_admin)
    reset_viewport

    @user.update!(preferences: (@user.preferences || {}).merge(
      "preview_features_enabled" => true,
      "transactions_compact" => true
    ))

    @entry = accounts(:depository).entries.create!(
      name: "Coffee",
      date: Date.current,
      amount: 5,
      currency: "USD",
      entryable: Transaction.new
    )
  end

  test "toggling checkboxes on mobile reveals the row selection checkbox" do
    page.current_window.resize_to(375, 800)

    visit transactions_url

    checkbox = find("##{dom_id(@entry, 'selection')}", visible: false)
    assert_not checkbox.visible?, "row checkbox should start hidden on mobile"

    find("#toggle-checkboxes-button").click

    assert checkbox.visible?, "row checkbox should become visible after tapping the toggle button"
  end

  test "toggling checkboxes on mobile reveals the row selection checkbox in flat (ungrouped) view" do
    @user.update!(preferences: @user.preferences.merge("transactions_group_by_date" => false))
    page.current_window.resize_to(375, 800)

    visit transactions_url

    checkbox = find("##{dom_id(@entry, 'selection')}", visible: false)
    assert_not checkbox.visible?, "row checkbox should start hidden on mobile"

    find("#toggle-checkboxes-button").click

    assert checkbox.visible?, "row checkbox should become visible after tapping the toggle button"
  end

  test "toggling checkboxes on mobile reveals the row selection checkbox in account activity" do
    page.current_window.resize_to(375, 800)

    visit account_url(accounts(:depository), tab: "activity")

    checkbox = find("##{dom_id(@entry, 'selection')}", visible: false)
    assert_not checkbox.visible?, "row checkbox should start hidden on mobile"

    find("#toggle-checkboxes-button").click

    assert checkbox.visible?, "row checkbox should become visible after tapping the toggle button"
  end

  test "flat header labels align with row columns on desktop transactions page" do
    @user.update!(preferences: @user.preferences.merge("transactions_group_by_date" => false))
    page.current_window.resize_to(1400, 900)

    visit transactions_url

    offsets = header_row_offsets("transactions", dom_id(@entry))

    assert_in_delta offsets["headerDate"], offsets["rowDate"], 1.0, "DATE header label is not aligned with row dates"
    assert_in_delta offsets["headerTxn"], offsets["rowTxn"], 1.0, "TRANSACTION header label is not aligned with row names"
  end

  test "flat header labels align with row columns on desktop account activity" do
    @user.update!(preferences: @user.preferences.merge("transactions_group_by_date" => false))
    page.current_window.resize_to(1400, 900)

    visit account_url(accounts(:depository), tab: "activity")

    frame_id = dom_id(accounts(:depository), "entries")
    offsets = header_row_offsets(frame_id, dom_id(@entry))

    assert_in_delta offsets["headerDate"], offsets["rowDate"], 1.0, "DATE header label is not aligned with row dates"
    assert_in_delta offsets["headerTxn"], offsets["rowTxn"], 1.0, "TRANSACTION header label is not aligned with row names"
  end

  test "split child tooltip responds to keyboard focus and Escape" do
    @entry.update!(amount: 100)
    @entry.split!([ { name: "First Part", amount: 60, category_id: nil }, { name: "Second Part", amount: 40, category_id: nil } ])
    child = @entry.child_entries.first
    @user.update!(preferences: @user.preferences.merge("show_split_grouped" => false))

    visit transactions_url

    within "turbo-frame##{dom_id(child)}" do
      link = find("a[aria-label='#{I18n.t('transactions.transaction.split_child_tooltip')}']")
      page.execute_script("arguments[0].focus()", link)
      assert_selector "[role='tooltip']", text: I18n.t("transactions.transaction.split_child_tooltip")
      link.send_keys(:escape)
      assert_no_selector "[role='tooltip']"
    end
  end

  test "compact row clicks open the drawer while selection stays independent" do
    visit transactions_url

    within "turbo-frame##{dom_id(@entry)}" do
      find("input[type='checkbox']").click
    end
    assert_no_selector "turbo-frame#drawer input[name='entry[name]']"

    within "turbo-frame##{dom_id(@entry)}" do
      find("p.privacy-sensitive").click
    end
    assert_selector "turbo-frame#drawer input[name='entry[name]']", wait: 10
  end

  test "mobile date and category share the same subtitle line" do
    @user.update!(preferences: @user.preferences.merge("transactions_group_by_date" => false))
    @entry.entryable.update!(category: categories(:food_and_drink))
    page.current_window.resize_to(375, 800)

    visit transactions_url

    positions = page.evaluate_script(<<~JS, dom_id(@entry))
      ((id) => {
        const row = document.getElementById(id);
        const date = row.querySelector('span[class~="lg:hidden"].shrink-0');
        const category = date.parentElement.querySelector("div.flex");
        return [date.getBoundingClientRect().top, category.getBoundingClientRect().top];
      })(arguments[0])
    JS
    assert_in_delta positions[0], positions[1], 2
  end

  private
    # Measures the left x-position of the DATE / TRANSACTION header labels
    # and of the first data row's date cell / name link, so we can assert
    # the header columns line up with the rows below them. Label matching
    # is case-insensitive because the header uppercases via CSS.
    def header_row_offsets(root_id, row_frame_id)
      page.evaluate_script(<<~JS, root_id, row_frame_id)
        ((rootId, frameId) => {
          const root = document.getElementById(rootId);
          const up = (el) => el.textContent.trim().toUpperCase();
          const dateCells = [...root.querySelectorAll('div.w-28')];
          const headerDate = dateCells.find((el) => up(el) === "DATE");
          const header = headerDate.closest("div.uppercase");
          const headerTxn = [...header.querySelectorAll("div")].find((el) => el.children.length === 0 && up(el) === "TRANSACTION");
          const rowDate = dateCells.find((el) => el !== headerDate && /\\d/.test(el.textContent));
          const rowLink = document.querySelector(`turbo-frame#${frameId} a`);
          const left = (el) => el.getBoundingClientRect().left;
          return { headerDate: left(headerDate), rowDate: left(rowDate), headerTxn: left(headerTxn), rowTxn: left(rowLink) };
        })(arguments[0], arguments[1])
      JS
    end

    def ensure_tailwind_build
      return if self.class.instance_variable_defined?(:@tailwind_css_built)

      system({ "RAILS_ENV" => "test" }, "bin/rails", "tailwindcss:build", exception: true)
      self.class.instance_variable_set(:@tailwind_css_built, true)
    end

    def teardown
      reset_viewport
      super
    end

    def reset_viewport
      page.current_window.resize_to(DEFAULT_VIEWPORT_WIDTH, DEFAULT_VIEWPORT_HEIGHT) if page&.current_window
    end
end
