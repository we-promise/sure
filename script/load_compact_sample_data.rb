# frozen_string_literal: true

class CompactSampleDataLoader
  RESET_ASSOCIATIONS = %i[
    budgets
    recurring_transactions
    rules
    imports
    plaid_items
    simplefin_items
    lunchflow_items
    enable_banking_items
    coinbase_items
    binance_items
    coinstats_items
    snaptrade_items
    indexa_capital_items
    mercury_items
    accounts
    categories
    tags
    merchants
    family_documents
    family_exports
    syncs
  ].freeze

  attr_reader :family, :user, :today

  def initialize(email:)
    @user = User.find_by(email: email)
    raise ActiveRecord::RecordNotFound, "User with email #{email} not found" unless @user

    @family = @user.family
    @today = Date.current
    @opening_balances = {}
    @accounts = {}
    @categories = {}
  end

  def run!
    ensure_safe_environment!

    puts "Loading compact sample data for family: #{family.name}"
    puts "Preserving user credentials for: #{user.email}"

    ActiveRecord::Base.transaction do
      reset_family_financial_data!
      create_categories!
      create_accounts!
      create_opening_valuations!
      create_sample_transactions!
      create_sample_transfers!
      create_edge_cases!
      update_balances_and_create_current_valuations!

      user.update!(default_account: @accounts.fetch(:checking))
    end

    print_summary!
  end

  private

    def ensure_safe_environment!
      return if Rails.env.development? || Rails.env.test? || ENV["ALLOW_COMPACT_SAMPLE_DATA_RESET"] == "1"

      raise "Refusing to reset family data outside development/test. Set ALLOW_COMPACT_SAMPLE_DATA_RESET=1 to override intentionally."
    end

    def reset_family_financial_data!
      family.users.update_all(default_account_id: nil)
      family.users.update_all(last_viewed_chat_id: nil)

      RESET_ASSOCIATIONS.each do |association_name|
        family.public_send(association_name).destroy_all
      end
    end

    def create_categories!
      @categories[:salary] = create_category!("Salary", "#22c55e", "circle-dollar-sign")
      @categories[:freelance] = create_category!("Freelance", "#16a34a", "briefcase")
      @categories[:bonus] = create_category!("Bonus", "#15803d", "sparkles")

      @categories[:housing] = create_category!("Housing", "#dc2626", "home")
      @categories[:utilities] = create_category!("Utilities", "#f59e0b", "lightbulb")
      @categories[:groceries] = create_category!("Groceries", "#65a30d", "shopping-bag")
      @categories[:dining] = create_category!("Dining", "#ea580c", "utensils")
      @categories[:transport] = create_category!("Transportation", "#0284c7", "car")
      @categories[:shopping] = create_category!("Shopping", "#2563eb", "shopping-cart")
      @categories[:entertainment] = create_category!("Entertainment", "#7c3aed", "drama")
      @categories[:healthcare] = create_category!("Healthcare", "#db2777", "pill")
      @categories[:insurance] = create_category!("Insurance", "#4f46e5", "shield")
      @categories[:travel] = create_category!("Travel", "#0891b2", "plane")
      @categories[:interest] = create_category!("Loan Interest", "#475569", "receipt")
    end

    def create_accounts!
      @accounts[:checking] = create_account!(
        name: "Chase Checking",
        accountable_type: "Depository",
        subtype: "checking",
        currency: "USD",
        opening_balance: 12_000
      )

      @accounts[:savings] = create_account!(
        name: "Marcus High-Yield Savings",
        accountable_type: "Depository",
        subtype: "savings",
        currency: "USD",
        opening_balance: 18_500
      )

      @accounts[:travel_eur] = create_account!(
        name: "Travel EUR Account",
        accountable_type: "Depository",
        subtype: "checking",
        currency: "EUR",
        opening_balance: 800
      )

      @accounts[:amex] = create_account!(
        name: "Amex Gold Card",
        accountable_type: "CreditCard",
        subtype: "credit_card",
        currency: "USD",
        opening_balance: 2_200
      )

      @accounts[:sapphire] = create_account!(
        name: "Chase Sapphire",
        accountable_type: "CreditCard",
        subtype: "credit_card",
        currency: "USD",
        opening_balance: 1_400
      )

      @accounts[:mortgage] = create_account!(
        name: "Home Mortgage",
        accountable_type: "Loan",
        subtype: "mortgage",
        currency: "USD",
        opening_balance: 285_000,
        cash_balance: 0
      )

      @accounts[:student_loan] = create_account!(
        name: "Student Loan",
        accountable_type: "Loan",
        subtype: "student",
        currency: "USD",
        opening_balance: 18_000,
        cash_balance: 0
      )

      @accounts[:auto_loan] = create_account!(
        name: "Auto Loan",
        accountable_type: "Loan",
        subtype: "auto",
        currency: "USD",
        opening_balance: 9_200,
        cash_balance: 0
      )

      @accounts[:brokerage] = create_account!(
        name: "Vanguard Brokerage",
        accountable_type: "Investment",
        subtype: "brokerage",
        currency: "USD",
        opening_balance: 46_000,
        cash_balance: 2_500
      )
    end

    def create_opening_valuations!
      opening_date = today - 95.days

      @accounts.each_value do |account|
        opening_balance = @opening_balances.fetch(account.id)

        account.entries.create!(
          date: opening_date,
          name: Valuation.build_opening_anchor_name(account.accountable_type),
          amount: opening_balance,
          currency: account.currency,
          user_modified: true,
          entryable: Valuation.new(kind: "opening_anchor")
        )
      end
    end

    def create_sample_transactions!
      [ 2, 1, 0 ].each do |months_ago|
        create_transaction!(account: @accounts[:checking], date: month_day(months_ago, 1), name: "Employer Payroll", amount: -4_800, category: @categories[:salary])
        create_transaction!(account: @accounts[:checking], date: month_day(months_ago, 15), name: "Employer Payroll", amount: -4_800, category: @categories[:salary])

        freelance_amount = months_ago == 1 ? -1_650 : -1_200
        create_transaction!(account: @accounts[:checking], date: month_day(months_ago, 10), name: "Freelance Client Payout", amount: freelance_amount, category: @categories[:freelance])

        create_transaction!(account: @accounts[:amex], date: month_day(months_ago, 5), name: "Whole Foods", amount: 430, category: @categories[:groceries])
        create_transaction!(account: @accounts[:amex], date: month_day(months_ago, 9), name: "Neighborhood Bistro", amount: 185, category: @categories[:dining])
        create_transaction!(account: @accounts[:amex], date: month_day(months_ago, 18), name: "City Transit", amount: 92, category: @categories[:transport])
        create_transaction!(account: @accounts[:amex], date: month_day(months_ago, 22), name: "Online Retail", amount: 145, category: @categories[:shopping])

        create_transaction!(account: @accounts[:sapphire], date: month_day(months_ago, 12), name: "Airline Ticket", amount: 160, category: @categories[:travel])
        create_transaction!(account: @accounts[:sapphire], date: month_day(months_ago, 20), name: "Streaming + Music", amount: 120, category: @categories[:entertainment])

        create_transaction!(account: @accounts[:checking], date: month_day(months_ago, 6), name: "Electric + Water Utility", amount: 245, category: @categories[:utilities])
        create_transaction!(account: @accounts[:checking], date: month_day(months_ago, 7), name: "Home Insurance", amount: 190, category: @categories[:insurance])
        create_transaction!(account: @accounts[:checking], date: month_day(months_ago, 8), name: "HOA Dues", amount: 360, category: @categories[:housing])
        create_transaction!(account: @accounts[:checking], date: month_day(months_ago, 17), name: "Pharmacy", amount: 96, category: @categories[:healthcare])

        create_transaction!(account: @accounts[:checking], date: month_day(months_ago, 3), name: "Mortgage Interest", amount: 980, category: @categories[:interest])
        create_transaction!(account: @accounts[:checking], date: month_day(months_ago, 4), name: "Student Loan Interest", amount: 85, category: @categories[:interest])
        create_transaction!(account: @accounts[:checking], date: month_day(months_ago, 4), name: "Auto Loan Interest", amount: 65, category: @categories[:interest])
      end
    end

    def create_sample_transfers!
      [ 2, 1, 0 ].each do |months_ago|
        create_transfer!(from: @accounts[:checking], to: @accounts[:savings], amount: 600, date: month_day(months_ago, 2))

        create_transfer!(from: @accounts[:checking], to: @accounts[:mortgage], amount: 1_650, date: month_day(months_ago, 3))
        create_transfer!(from: @accounts[:checking], to: @accounts[:student_loan], amount: 320, date: month_day(months_ago, 4))
        create_transfer!(from: @accounts[:checking], to: @accounts[:auto_loan], amount: 290, date: month_day(months_ago, 4))

        create_transfer!(from: @accounts[:checking], to: @accounts[:brokerage], amount: 700, date: month_day(months_ago, 11))

        create_transfer!(from: @accounts[:checking], to: @accounts[:amex], amount: 950, date: month_day(months_ago, 26))
        create_transfer!(from: @accounts[:checking], to: @accounts[:sapphire], amount: 760, date: month_day(months_ago, 27))
      end

      create_transfer!(from: @accounts[:savings], to: @accounts[:checking], amount: 500, date: month_day(0, 13))

      create_transfer!(
        from: @accounts[:checking],
        to: @accounts[:travel_eur],
        amount: 350,
        date: month_day(1, 24),
        exchange_rate: 0.92
      )

      create_transfer!(
        from: @accounts[:travel_eur],
        to: @accounts[:checking],
        amount: 120,
        date: month_day(0, 9),
        exchange_rate: 1.08
      )
    end

    def create_edge_cases!
      create_transaction!(
        account: @accounts[:checking],
        date: month_day(1, 20),
        name: "Annual Bonus",
        amount: -3_500,
        category: @categories[:bonus],
        kind: "one_time"
      )

      create_transaction!(
        account: @accounts[:amex],
        date: month_day(0, 28),
        name: "Coffee Shop Pending",
        amount: 63.25,
        category: @categories[:dining],
        extra: { "simplefin" => { "pending" => true } }
      )

      create_transaction!(
        account: @accounts[:checking],
        date: month_day(0, 23),
        name: "Mystery Charge",
        amount: 47.11,
        category: nil
      )

      create_transaction!(
        account: @accounts[:amex],
        date: month_day(0, 21),
        name: "Online Return",
        amount: -42,
        category: @categories[:shopping]
      )
    end

    def update_balances_and_create_current_valuations!
      @accounts.each_value do |account|
        opening_balance = @opening_balances.fetch(account.id)
        transaction_sum = account.entries.where(entryable_type: "Transaction").sum(:amount).to_d

        final_balance = if account.liability?
          opening_balance + transaction_sum
        else
          opening_balance - transaction_sum
        end

        account.update!(
          balance: final_balance,
          cash_balance: final_cash_balance_for(account, final_balance)
        )

        account.entries.create!(
          date: today,
          name: Valuation.build_current_anchor_name(account.accountable_type),
          amount: final_balance,
          currency: account.currency,
          user_modified: true,
          entryable: Valuation.new(kind: "current_anchor")
        )
      end
    end

    def final_cash_balance_for(account, final_balance)
      if account.loan? || account.other_liability?
        0
      elsif account.investment? || account.crypto?
        account.cash_balance
      else
        final_balance
      end
    end

    def create_category!(name, color, icon)
      family.categories.create!(name: name, color: color, lucide_icon: icon)
    end

    def create_account!(name:, accountable_type:, subtype:, currency:, opening_balance:, cash_balance: nil)
      account = family.accounts.create!(
        owner: user,
        name: name,
        balance: opening_balance,
        cash_balance: cash_balance.nil? ? opening_balance : cash_balance,
        currency: currency,
        accountable: accountable_type.constantize.new(subtype: subtype)
      )

      @opening_balances[account.id] = opening_balance.to_d
      account
    end

    def create_transaction!(account:, date:, name:, amount:, category:, kind: "standard", extra: {})
      account.entries.create!(
        date: date,
        name: name,
        amount: amount,
        currency: account.currency,
        user_modified: true,
        entryable: Transaction.new(
          category: category,
          kind: kind,
          extra: extra
        )
      )
    end

    def create_transfer!(from:, to:, amount:, date:, exchange_rate: nil)
      transfer = Transfer::Creator.new(
        family: family,
        source_account_id: from.id,
        destination_account_id: to.id,
        date: date,
        amount: amount,
        exchange_rate: exchange_rate
      ).create

      raise "Transfer creation failed from #{from.name} to #{to.name}" unless transfer.persisted?

      transfer
    end

    def month_day(months_ago, day)
      month = today << months_ago
      safe_day = [ day, Time.days_in_month(month.month, month.year) ].min
      computed = Date.new(month.year, month.month, safe_day)

      months_ago.zero? ? [ computed, today ].min : computed
    end

    def print_summary!
      transfer_count = Transfer
        .joins(outflow_transaction: { entry: :account })
        .where(accounts: { family_id: family.id })
        .count

      puts ""
      puts "Compact sample data load complete"
      puts "Accounts: #{family.accounts.count}"
      puts "Categories: #{family.categories.count}"
      puts "Transactions: #{family.transactions.count}"
      puts "Transfers: #{transfer_count}"
      puts "Transaction kinds: #{family.transactions.group(:kind).count}"
      puts ""
      puts "Account balances:"
      family.accounts.order(:name).each do |account|
        puts "- #{account.name} (#{account.accountable_type}) -> #{account.balance.to_f.round(2)} #{account.currency}"
      end
    end
end

email = ENV.fetch("SAMPLE_EMAIL", "user@example.com")
CompactSampleDataLoader.new(email: email).run!
