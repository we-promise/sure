require "application_system_test_case"

# Immediate rules change a transaction in the background, often while its
# drawer is still open. The drawer's next save must not undo those changes.
class TransactionDrawerRuleChangesTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
  end

  test "saving the date keeps a category a rule set while the drawer was open" do
    transaction = transactions(:one)
    transaction.update!(category: nil)
    entry = transaction.entry

    open_drawer(entry)

    # What an immediate rule does in the background after the drawer loaded.
    transaction.update!(category: categories(:food_and_drink))
    new_date = entry.date - 1.day

    within "turbo-frame#drawer", visible: :all do
      find("input[name='entry[date]']").set(new_date)
    end

    assert_selector "##{ActionView::RecordIdentifier.dom_id(entry)}", text: "Food & Drink"
    assert_equal new_date, entry.reload.date
    assert_equal categories(:food_and_drink), transaction.reload.category
  end

  test "picking a tag keeps a tag a rule added while the drawer was open" do
    transaction = transactions(:one)
    transaction.update!(tag_ids: [ tags(:one).id ])
    entry = transaction.entry
    rule_tag = @user.family.tags.create!(name: "Added by a rule")

    open_drawer(entry)

    # What an immediate rule does in the background after the drawer loaded.
    transaction.update!(tag_ids: [ tags(:one).id, rule_tag.id ])

    within "turbo-frame#drawer", visible: :all do
      find("summary", text: /details/i).click
      find("[data-controller='tag-select'] [data-tag-select-target='button']").click
      find("[data-tag-select-target='option'][data-tag-id='#{tags(:two).id}']").click
    end

    expected = [ tags(:one).id, tags(:two).id, rule_tag.id ].sort
    wait_until { transaction.reload.tag_ids.sort == expected }
    assert_equal expected, transaction.reload.tag_ids.sort
  end

  test "picking and quickly unpicking a tag leaves it off" do
    transaction = transactions(:one)
    transaction.update!(tag_ids: [ tags(:one).id ])
    entry = transaction.entry

    open_drawer(entry)

    within "turbo-frame#drawer", visible: :all do
      find("summary", text: /details/i).click
      find("[data-controller='tag-select'] [data-tag-select-target='button']").click
      option = find("[data-tag-select-target='option'][data-tag-id='#{tags(:two).id}']")
      option.click
      option.click
    end

    # Both saves have landed once the second request is done; wait for the
    # page's queue rather than the database, which already matches at first.
    page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1]
      const element = document.querySelector("turbo-frame#drawer [data-controller='tag-select']")
      const controller = window.Stimulus.getControllerForElementAndIdentifier(element, "tag-select")
      Promise.resolve(controller.saveQueue).then(() => done(), () => done())
    JS

    assert_equal [ tags(:one).id ], transaction.reload.tag_ids
  end

  private
    def open_drawer(entry)
      visit transactions_url

      page.execute_script <<~JS
        const frame = document.querySelector("turbo-frame#drawer")
        frame.src = "#{transaction_url(entry)}"
      JS

      within "turbo-frame#drawer", visible: :all do
        assert_selector "[data-controller='category-select']"
      end
    end

    # The tag picker saves with fetch, so there's no page change to wait on.
    def wait_until(timeout: Capybara.default_max_wait_time)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      sleep 0.05 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    end
end
