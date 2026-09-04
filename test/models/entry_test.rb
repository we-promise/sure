require "test_helper"

class EntryTest < ActiveSupport::TestCase
  include EntriesTestHelper

  test "chronological ordering uses id as final tie breaker" do
    account = accounts(:depository)
    timestamp = Time.zone.parse("2026-05-05 12:00:00")

    entries = 3.times.map do |index|
      create_transaction(
        account: account,
        name: "Same timestamp transaction #{index}",
        date: Date.new(2026, 5, 5),
        created_at: timestamp,
        updated_at: timestamp
      )
    end

    entry_ids = entries.map(&:id)

    assert_equal entry_ids.sort, Entry.where(id: entry_ids).chronological.pluck(:id)
    assert_equal entry_ids.sort.reverse, Entry.where(id: entry_ids).reverse_chronological.pluck(:id)
  end

  test "bulk_update! touches the assigned category's last_used_at" do
    entry = create_transaction(account: accounts(:depository))
    category = categories(:income)
    assert_nil category.last_used_at

    Entry.where(id: entry.id).bulk_update!({ category_id: category.id })

    assert_not_nil category.reload.last_used_at
  end

  test "blank name is invalid when auto-generate transaction names is off" do
    families(:dylan_family).update!(auto_generate_transaction_names: false)

    entry = Entry.new(
      account: accounts(:depository),
      name: "",
      date: Date.current,
      currency: "USD",
      amount: 100,
      entryable: Transaction.new
    )

    assert_not entry.valid?
    assert_includes entry.errors[:name], "can't be blank"
  end

  test "auto-generates name from merchant when blank and merchant is set" do
    families(:dylan_family).update!(auto_generate_transaction_names: true)

    entry = create_transaction(
      account: accounts(:depository),
      name: "",
      merchant: merchants(:netflix)
    )

    assert_equal merchants(:netflix).name, entry.name
  end

  test "auto-generates name from category when blank and only category is set" do
    families(:dylan_family).update!(auto_generate_transaction_names: true)

    entry = create_transaction(
      account: accounts(:depository),
      name: "",
      category: categories(:food_and_drink)
    )

    assert_equal categories(:food_and_drink).display_name, entry.name
  end

  test "blank name is still invalid when auto-generate is on but neither merchant nor category is set" do
    families(:dylan_family).update!(auto_generate_transaction_names: true)

    entry = Entry.new(
      account: accounts(:depository),
      name: "",
      date: Date.current,
      currency: "USD",
      amount: 100,
      entryable: Transaction.new
    )

    assert_not entry.valid?
    assert_includes entry.errors[:name], "can't be blank"
  end

  test "combines merchant and category with a dash when both are set" do
    families(:dylan_family).update!(auto_generate_transaction_names: true)

    entry = create_transaction(
      account: accounts(:depository),
      name: "",
      merchant: merchants(:netflix),
      category: categories(:food_and_drink)
    )

    assert_equal "#{categories(:food_and_drink).display_name} - #{merchants(:netflix).name}", entry.name
  end

  test "does not overwrite an explicitly provided name even when auto-generate is on" do
    families(:dylan_family).update!(auto_generate_transaction_names: true)

    entry = create_transaction(
      account: accounts(:depository),
      name: "Explicit name",
      merchant: merchants(:netflix)
    )

    assert_equal "Explicit name", entry.name
  end

  test "generic_name? is true for the auto-generated fallback label" do
    entry = create_transaction(account: accounts(:depository), name: I18n.t("transactions.unknown_name"))

    assert entry.generic_name?
  end

  test "generic_name? is true when the name exactly matches the entry's category" do
    entry = create_transaction(
      account: accounts(:depository),
      name: categories(:food_and_drink).display_name,
      category: categories(:food_and_drink)
    )

    assert entry.generic_name?
  end

  test "generic_name? is false for a distinguishing name" do
    entry = create_transaction(account: accounts(:depository), name: "Starbucks #4521")

    assert_not entry.generic_name?
  end
end
