require "application_system_test_case"

class CompactTransactionsMobileTest < ApplicationSystemTestCase
  DEFAULT_VIEWPORT_WIDTH = 2400
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

  test "labels stay hidden in mobile-style rows" do
    @entry.entryable.update!(tags: [ tags(:one) ])

    [ 375, 1400 ].each do |width|
      page.current_window.resize_to(width, 900)
      [ transactions_url, account_url(accounts(:depository), tab: "activity") ].each do |url|
        visit url
        within "turbo-frame##{dom_id(@entry)}" do
          assert_no_selector "##{dom_id(@entry.entryable, 'tag_summary_mobile')}"
          assert_no_selector "##{dom_id(@entry.entryable, 'tag_summary_desktop')}"
          assert_no_text tags(:one).name
        end
      end
    end
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
    page.current_window.resize_to(2400, 900)

    visit transactions_url

    offsets = header_row_offsets("transactions", dom_id(@entry))

    assert_in_delta offsets["headerDate"], offsets["rowDate"], 1.0, "DATE header label is not aligned with row dates"
    assert_in_delta offsets["headerTxn"], offsets["rowTxn"], 1.0, "TRANSACTION header label is not aligned with row names"
  end

  test "flat header labels align with row columns on desktop account activity" do
    @user.update!(preferences: @user.preferences.merge("transactions_group_by_date" => false))
    page.current_window.resize_to(2400, 900)

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

  test "untagged desktop transactions keep compact row height in grouped and flat views" do
    [ true, false ].each do |grouped|
      @user.update!(preferences: @user.preferences.merge("transactions_group_by_date" => grouped))
      visit transactions_url

      geometry = compact_row_geometry
      assert_operator geometry["height"], :<=, 60, "an empty tag control must not add a separate line"
      assert_in_delta geometry["nameCenter"], geometry["amountCenter"], 12, "name should stay near the amount's baseline"
    end
  end

  test "desktop account names align vertically with amounts and dates without tags" do
    @user.update!(preferences: @user.preferences.merge("transactions_group_by_date" => false))

    [ "standard", "funds_movement" ].each do |kind|
      @entry.entryable.update!(kind: kind)
      visit account_url(accounts(:depository), tab: "activity")

      geometry = compact_row_geometry
      assert_operator geometry["height"], :<=, 48, "single-line account rows should remain compact"
      assert_in_delta geometry["nameCenter"], geometry["amountCenter"], 2, "name and amount should align vertically"
      assert_in_delta geometry["nameCenter"], geometry["dateCenter"], 2, "name and date should align vertically"
    end
  end

  test "desktop tags stay in the labels column without adding a row line" do
    @entry.entryable.update!(tags: [ tags(:one), tags(:two) ])
    visit transactions_url

    within "turbo-frame##{dom_id(@entry)}" do
      find("##{dom_id(@entry.entryable, 'tag_summary_desktop')}").hover
      assert_selector '[role="tooltip"]', text: tags(:one).name
      assert_selector '[role="tooltip"]', text: tags(:two).name
    end
    geometry = compact_row_geometry
    assert_operator geometry["height"], :<=, 60, "labels must not add a row line"
  end

  test "desktop columns align and share remaining space with and without notes" do
    page.current_window.resize_to(2400, 1200)
    @entry.update!(amount: 12_345_678.90, notes: "Notes stay in their own column")
    @entry.entryable.update!(tags: [ tags(:one), tags(:two) ])

    [ true, false ].each do |show_notes|
      @user.update!(preferences: @user.preferences.merge("transactions_group_by_date" => false, "transactions_show_notes" => show_notes))

      [ transactions_url, account_url(accounts(:depository), tab: "activity") ].each do |url|
        visit url
        layout = page.evaluate_script(<<~JS, dom_id(@entry))
          ((id) => {
            const row = document.getElementById(id).querySelector('[role="row"]');
            const headers = [...row.closest('[role="table"]').querySelectorAll('[role="columnheader"]')];
            const cells = [...row.children];
            const columns = Object.fromEntries(headers.map((header, index) => {
              const rect = cells[index].getBoundingClientRect();
              return [header.textContent.trim().toLowerCase(), {
                width: rect.width, left: rect.left, headerLeft: header.getBoundingClientRect().left
              }];
            }));
            const amount = row.querySelector('p.privacy-sensitive');
            const labels = row.querySelector('[id^="tag_summary_desktop"]');
            return {
              columns,
              order: headers.map(header => header.textContent.trim().toLowerCase()),
              labelsCell: cells.indexOf(labels.closest('[role="cell"]')),
              amountFits: amount.scrollWidth <= amount.clientWidth,
              rowHeight: row.getBoundingClientRect().height
            };
          })(arguments[0])
        JS

        columns = layout["columns"]
        columns.each_value { |column| assert_in_delta column["headerLeft"], column["left"], 1 }
        assert_equal layout["order"].index("category") + 1, layout["labelsCell"]
        assert_equal "labels", layout["order"][layout["labelsCell"]]
        assert_in_delta columns["amount"]["width"], columns["labels"]["width"], 1
        assert_in_delta 2.5, columns["transaction"]["width"].fdiv(columns["category"]["width"]), 0.05
        if show_notes
          assert_in_delta columns["transaction"]["width"], columns["notes"]["width"], 1
        else
          assert_not columns.key?("notes")
        end
        assert layout["amountFits"], "large amounts should fit without truncation"
        assert_operator layout["rowHeight"], :<=, 60, "labels must remain on one line"
      end
    end
  end

  test "transfer account information remains available on name hover" do
    page.current_window.resize_to(2400, 1200)
    @entry.entryable.update!(kind: "funds_movement")
    visit transactions_url

    within "turbo-frame##{dom_id(@entry)}" do
      find('[data-clickable-row-target="link"]').hover
      assert_selector '[role="tooltip"]', text: accounts(:depository).name
    end
  end

  test "narrow desktop tables use mobile rows and retain selection and category information" do
    page.current_window.resize_to(1400, 900)
    @user.update!(preferences: @user.preferences.merge("transactions_group_by_date" => false, "transactions_show_notes" => true))
    @entry.update!(notes: "Desktop notes")
    @entry.entryable.update!(category: categories(:food_and_drink), tags: [ tags(:one) ])

    [ transactions_url, account_url(accounts(:depository), tab: "activity") ].each do |url|
      visit url
      within "turbo-frame##{dom_id(@entry)}" do
        assert_no_selector "div.w-28"
        assert_selector "#category_name_mobile_#{@entry.entryable_id}", text: categories(:food_and_drink).name
        assert_no_selector "##{dom_id(@entry.entryable, 'tag_summary_mobile')}"
        assert_no_selector "##{dom_id(@entry.entryable, 'tag_summary_desktop')}"
        assert_no_selector "input[type='checkbox']"
        assert_no_text @entry.notes
      end
      find("#toggle-checkboxes-button").click
      within "turbo-frame##{dom_id(@entry)}" do
        assert_selector "input[type='checkbox']"
      end
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
        const date = row.querySelector('span[class~="@5xl/compact-table:hidden"].shrink-0');
        const category = date.parentElement.querySelector("div.flex");
        return [date.getBoundingClientRect().top, category.getBoundingClientRect().top];
      })(arguments[0])
    JS
    assert_in_delta positions[0], positions[1], 2
  end

  private
    def compact_row_geometry
      page.evaluate_script(<<~JS, dom_id(@entry))
        ((id) => {
          const row = document.getElementById(id).querySelector('[role="row"]');
          const center = (el) => {
            const rect = el.getBoundingClientRect();
            return rect.top + rect.height / 2;
          };
          const date = row.querySelector('div.w-28');
          return {
            height: row.getBoundingClientRect().height,
            nameCenter: center(row.querySelector('[data-clickable-row-target="link"]')),
            amountCenter: center(row.querySelector('p.privacy-sensitive')),
            dateCenter: date ? center(date) : null
          };
        })(arguments[0])
      JS
    end

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
