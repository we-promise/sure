require "test_helper"

class Demo::FinancekitGeneratorTest < ActiveSupport::TestCase
  setup do
    travel_to Time.utc(2026, 9, 23, 20)
    @checking = accounts(:depository)
    @checking.update!(name: "Chase Premier Checking")
    @checking.depository.update!(subtype: "checking")
  end

  test "FinanceKit demo accounts and transactions can be generated in separate phases in production" do
    Rails.stubs(:env).returns(ActiveSupport::EnvironmentInquirer.new("production"))
    generator = Demo::FinancekitGenerator.new(families(:dylan_family))

    item = nil
    assert_no_difference "Entry.count" do
      item = generator.create_accounts!
    end
    assert_equal [ "Apple Card", "Apple Cash", "Nancy's Apple Cash" ], item.accounts.order(:name).pluck(:name)
    assert item.accounts.all?(&:linked?)
    assert_nil item.last_imported_at

    assert_no_difference "Account.count" do
      generator.create_transactions!
    end
    assert item.reload.last_imported_at
    assert item.accounts.all? { |account| account.entries.exists? }
    assert_no_difference [ "Account.count", "Entry.count", "FinancekitTransaction.count", "Transfer.count" ] do
      generator.create_accounts!
      generator.create_transactions!
    end
  end

  test "seeds linked Apple Card and Apple Cash with source identities and realistic activity" do
    family = families(:dylan_family)
    item = Demo::FinancekitGenerator.new(family).generate!

    assert_equal "active", item.status
    assert_equal 3, item.accounts.count
    assert item.last_accepted_at
    assert item.last_imported_at

    card = item.accounts.find_by!(name: "Apple Card")
    cash = item.accounts.find_by!(name: "Apple Cash")
    assert_equal "CreditCard", card.accountable_type
    assert_equal "cash", cash.depository.subtype
    assert card.entries.where(name: "Apple Card Payment").all? { |entry| entry.amount.negative? }
    assert cash.entries.where(name: "Apple Cash Top Up").all? { |entry| entry.amount.negative? }
    assert card.entries.where(name: Demo::FinancekitGenerator::CARD_MERCHANTS).exists?
    assert cash.entries.where(name: Demo::FinancekitGenerator::CASH_MERCHANTS).exists?

    [ card, cash ].each do |account|
      account.entries.where(name: Demo::FinancekitGenerator::MERCHANT_CATEGORIES.keys).each do |entry|
        assert_equal Demo::FinancekitGenerator::MERCHANT_CATEGORIES.fetch(entry.name), entry.entryable.category.name
      end
      payments = account.entries.where(name: Demo::FinancekitGenerator::FUNDING_ENTRIES)
      assert_equal 12, payments.count
      payments.each do |entry|
        transfer = entry.entryable.transfer
        assert_equal @checking, transfer.from_account
        assert_equal account, transfer.to_account
        assert_equal -entry.amount, transfer.outflow_transaction.entry.amount
        assert_equal entry.date, transfer.outflow_transaction.entry.date
        assert_equal "funds_movement", entry.entryable.kind
        assert_equal(account.credit_card? ? "cc_payment" : "funds_movement", transfer.outflow_transaction.kind)
        assert_nil entry.entryable.category
      end
    end

    item.financekit_accounts.each do |mapping|
      assert_equal "financekit", mapping.account.account_providers.first.provider_name
      assert_equal mapping.account.entries.count, mapping.financekit_transactions.count
      assert mapping.financekit_transactions.where(status: "pending").exists? unless mapping.source_id == Demo::FinancekitGenerator::NANCY_SOURCE_ID
      assert mapping.financekit_transactions.where(status: "booked").exists?
      assert mapping.financekit_transactions.all?(&:ledger_imported?)
      assert_equal [ "financekit" ], mapping.account.entries.distinct.pluck(:source)
      assert mapping.account.entries.all? { |entry| entry.date <= Date.current }
      total = mapping.financekit_transactions.where(status: "booked").joins(:entry).sum("entries.amount")
      expected = mapping.accountable_type == "CreditCard" ? total : -total
      assert_in_delta expected, mapping.account.reload.balance, 0.01
    end
  end

  test "rerunning demo seeding preserves existing accounts and transactions" do
    family = families(:dylan_family)
    generator = Demo::FinancekitGenerator.new(family)
    item = generator.generate!
    account = item.accounts.find_by!(name: "Apple Card")
    account.update!(name: "Renamed Wallet account")

    purchase = account.entries.where("amount > 0").first.entryable
    purchase.update!(category: categories(:one))

    assert_no_difference [ "Account.count", "Entry.count", "FinancekitItem.count", "FinancekitTransaction.count", "Transfer.count", "Category.count" ] do
      assert_equal item.id, generator.generate!.id
    end
    assert_equal "Renamed Wallet account", account.reload.name
    assert_equal categories(:one), purchase.reload.category
  end

  test "repairs old demo categories and unpaired payments without replacing source records" do
    family = families(:dylan_family)
    item = Demo::FinancekitGenerator.new(family).generate!
    card = item.accounts.find_by!(name: "Apple Card")
    cash = item.accounts.find_by!(name: "Apple Cash")
    purchases = [ card.entries.find_by!(name: "Delta Airlines"), cash.entries.find_by!(name: "Coffee Shop") ]
    payment = card.entries.find_by!(name: "Apple Card Payment")
    transfer = payment.entryable.transfer
    outflow = transfer.outflow_transaction.entry
    transfer.destroy!
    outflow.destroy!
    (purchases + [ payment ]).each do |entry|
      transaction = entry.entryable.reload
      transaction.update!(category: family.categories.find_by!(name: "Shopping"),
        extra: transaction.extra.except("demo_financekit_activity_version"))
    end
    source_records = item.financekit_accounts.flat_map { |mapping| mapping.financekit_transactions.pluck(:id, :entry_id, :raw_payload) }
    balances = [ card.balance, cash.balance ]

    assert_difference [ "Entry.count", "Transfer.count" ], 1 do
      assert_no_difference [ "Account.count", "FinancekitTransaction.count" ] do
        Demo::FinancekitGenerator.new(family).generate!
      end
    end

    assert_equal "Travel", purchases.first.reload.entryable.category.name
    assert_equal "Coffee & Takeout", purchases.last.reload.entryable.category.name
    assert_equal @checking, payment.reload.entryable.transfer.from_account
    assert_nil payment.entryable.category
    assert_equal balances, [ card.reload.balance, cash.reload.balance ]
    assert_equal source_records, item.financekit_accounts.flat_map { |mapping| mapping.financekit_transactions.pluck(:id, :entry_id, :raw_payload) }
  end

  test "standalone demo uses a funded synthetic checking account when demo checking is absent" do
    family = families(:empty)
    item = Demo::FinancekitGenerator.new(family).generate!
    checking = family.accounts.find_by!(name: "Wallet Demo Checking")
    assert_equal item.user, checking.owner
    assert_in_delta 5_000, checking.balance, 0.01
    assert_not @checking.entries.where(name: "Apple Card Payment").exists?

    assert_no_difference [ "Account.count", "Entry.count", "Transfer.count" ] do
      Demo::FinancekitGenerator.new(family).generate!
    end
  end

  test "Daily Cash is next-day cash back on booked card purchases, not payments or pending charges" do
    item = Demo::FinancekitGenerator.new(families(:dylan_family)).generate!
    card = item.accounts.find_by!(name: "Apple Card")
    cash = item.accounts.find_by!(name: "Apple Cash")
    purchases = card.entries.excluding_pending.where("amount > 0 AND date < ?", Date.current)
    totals = purchases.group(:date).sum(:amount)
    rewards = cash.entries.where(name: "Apple Card Daily Cash")

    assert_operator rewards.count, :>, 100
    assert_equal totals.size, rewards.count
    rewards.each do |entry|
      assert_equal -(totals.fetch(entry.date.prev_day) * BigDecimal("0.01")).round(2), entry.amount
      assert_equal "Cash Back", entry.entryable.category.name
      assert_equal "standard", entry.entryable.kind
      assert_nil entry.entryable.transfer
      assert_operator entry.date, :<=, Date.current
    end
  end

  test "upgrades an existing two-account demo with Nancy without replacing the original accounts" do
    family = families(:dylan_family)
    item = Demo::FinancekitGenerator.new(family).generate!
    mapping = item.financekit_accounts.find_by!(source_id: Demo::FinancekitGenerator::NANCY_SOURCE_ID)
    nancy = mapping.account
    nancy.entries.each do |entry|
      transfer = entry.entryable.transfer
      next unless transfer

      counterpart = transfer.outflow_transaction.entry
      FinancekitTransaction.where(entry: counterpart).destroy_all
      counterpart.destroy!
    end
    lineage = mapping.financekit_account_lineage
    mapping.destroy!
    lineage.destroy!
    nancy.destroy!
    item.update!(consent: item.consent.merge("selected_source_account_ids" => [ Demo::FinancekitGenerator::CARD_SOURCE_ID, Demo::FinancekitGenerator::CASH_SOURCE_ID ]))
    original_accounts = item.accounts.pluck(:id)
    original_entries = Entry.where(account_id: original_accounts).order(:id).pluck(:id, :amount)

    assert_difference "Account.count", 1 do
      Demo::FinancekitGenerator.new(family).generate!
    end
    assert_equal "active", item.reload.status
    assert_equal 3, item.accounts.count
    assert_equal 12, item.accounts.find_by!(name: "Nancy's Apple Cash").entries.count
    assert_equal original_entries, Entry.where(id: original_entries.map(&:first)).order(:id).pluck(:id, :amount)
  end

  test "Nancy has six linked gifts and spends her allowance on small outings" do
    item = Demo::FinancekitGenerator.new(families(:dylan_family)).generate!
    cash = item.accounts.find_by!(name: "Apple Cash")
    nancy = item.accounts.find_by!(name: "Nancy's Apple Cash")

    assert_equal "cash", nancy.depository.subtype
    assert_equal cash.family, nancy.family
    assert_equal 12, nancy.entries.count
    assert_includes item.consented_source_ids, Demo::FinancekitGenerator::NANCY_SOURCE_ID
    gifts = nancy.entries.where("amount < 0")
    assert_equal 6, gifts.count
    gifts.each do |entry|
      transfer = entry.entryable.transfer
      assert_equal cash, transfer.from_account
      assert_equal nancy, transfer.to_account
      assert_equal entry.date, transfer.outflow_transaction.entry.date
      assert_equal -entry.amount, transfer.outflow_transaction.entry.amount
      assert_equal "funds_movement", entry.entryable.kind
      assert_equal "funds_movement", transfer.outflow_transaction.kind
    end
    purchases = nancy.entries.where("amount > 0").order(:date)
    assert_equal 6, purchases.count
    assert_equal [ "Candy Shop", "Movie Theater", "After-School Snacks", "Movie Theater", "Ice Cream Shop", "Candy Shop" ], purchases.pluck(:name)
    assert_equal [ "Food & Dining", "Entertainment", "Food & Dining", "Entertainment", "Food & Dining", "Food & Dining" ], purchases.map { |entry| entry.entryable.category.name }
    purchases.each do |entry|
      assert_nil entry.entryable.transfer
      assert_equal "standard", entry.entryable.kind
      assert_operator entry.date, :<=, Date.current
    end
    balance = 0
    nancy.entries.order(:date).each do |entry|
      balance -= entry.amount
      assert_operator balance, :>=, 0, "Nancy cannot spend money before receiving it"
    end
    assert_in_delta 17.50, nancy.balance, 0.01
    assert_equal -nancy.entries.sum(:amount), nancy.balance
  end
end
