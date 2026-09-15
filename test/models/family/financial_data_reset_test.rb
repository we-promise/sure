require "test_helper"

class Family::FinancialDataResetTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @other_family = families(:empty)
    @other_category = @other_family.categories.create!(
      name: "Keep Me",
      color: "#12B76A",
      lucide_icon: "tag"
    )
    Provider::Registry.stubs(:plaid_provider_for_region).returns(nil)
  end

  test "dry run reports target counts and deletes nothing" do
    result = Family::FinancialDataReset.new(user: @user).call

    assert result.dry_run
    assert_operator result.before_counts[:accounts], :>, 0
    assert_operator result.before_counts[:categories], :>, 0
    assert_equal result.before_counts, result.after_counts
    assert result.deleted_counts.values.all?(&:zero?)
    assert User.exists?(@user.id)
  end

  test "provider item associations are limited to explicit syncable family associations" do
    associations = Family::FinancialDataReset.provider_item_associations

    assert_not_empty associations
    assert_equal associations, Family::FinancialDataReset::PROVIDER_ITEM_ASSOCIATIONS
    assert associations.all? { |name| name.to_s.end_with?("_items") }

    associations.each do |name|
      reflection = Family.reflect_on_association(name)

      assert reflection
      assert_equal :has_many, reflection.macro
      assert_includes reflection.klass.included_modules, Syncable
    end
  end

  test "sync counts use the family sync scope without double counting" do
    account = @family.accounts.first
    provider_item = @family.plaid_items.first
    @family.syncs.create!
    account.syncs.create!
    provider_item.syncs.create!

    result = Family::FinancialDataReset.new(user: @user).call

    assert_equal Sync.for_family(@family).count, result.before_counts[:syncs]
  end

  test "destructive reset requires explicit confirmation" do
    assert_raises Family::FinancialDataReset::ConfirmationRequiredError do
      Family::FinancialDataReset.new(user: @user, dry_run: false).call
    end
  end

  test "report: false skips count queries but still deletes financial data" do
    assert_operator @family.accounts.count, :>, 0

    result = Family::FinancialDataReset.new(
      user: @user,
      dry_run: false,
      confirmed: true,
      report: false
    ).call

    assert_equal({}, result.before_counts)
    assert_equal({}, result.after_counts)
    assert result.deleted_counts.values.all?(&:zero?)
    assert_equal 0, @family.reload.accounts.count
    assert User.exists?(@user.id)
  end

  test "destructive reset without confirmation does not partially mutate financial data" do
    create_extra_target_data!(family: @family, label: "Unconfirmed")
    before_counts = reset_counts(@family)

    assert_raises Family::FinancialDataReset::ConfirmationRequiredError do
      Family::FinancialDataReset.new(user: @user, dry_run: false).call
    end

    assert_equal before_counts, reset_counts(@family)
    assert User.exists?(@user.id)
  end

  test "rejects mismatched user and family inputs" do
    error = assert_raises ArgumentError do
      Family::FinancialDataReset.new(user: @user, family: @other_family)
    end

    assert_equal "user and family must belong to the same family", error.message
  end

  test "destructive reset preserves financial data for other families" do
    create_extra_target_data!(family: @family, label: "Current Family")
    other_records = create_extra_target_data!(family: @other_family, label: "Other Family")
    other_family_counts = reset_counts(@other_family)

    assert_no_changes -> { reset_target_snapshot(other_records) } do
      Family::FinancialDataReset.new(
        user: @user,
        dry_run: false,
        confirmed: true
      ).call
    end

    assert_equal 0, reset_counts(@family).values.sum
    assert_equal other_family_counts, reset_counts(@other_family)
  end

  test "destructive reset clears financial data for one family and preserves users" do
    create_extra_target_data!(family: @family, label: "Reset Test")

    result = Family::FinancialDataReset.new(
      user: @user,
      dry_run: false,
      confirmed: true
    ).call

    assert_not result.dry_run
    assert result.before_counts.values.any?(&:positive?)
    assert_equal 0, result.after_counts.values.sum
    assert result.deleted_counts.values.any?(&:positive?)
    assert User.exists?(@user.id)
    assert_equal @family.id, User.find(@user.id).family_id
    assert Category.exists?(@other_category.id)
  end

  test "destructive reset revokes provider item and clears provider account attachments" do
    account = @other_family.accounts.create!(
      name: "Provider Reset Checking",
      balance: 100,
      currency: "USD",
      accountable: Depository.new
    )
    plaid_item = @other_family.plaid_items.create!(
      name: "Provider Reset Bank",
      plaid_id: "provider_reset_item",
      access_token: "provider_reset_access_token",
      plaid_region: "us"
    )
    plaid_account = plaid_item.plaid_accounts.create!(
      plaid_id: "provider_reset_account",
      plaid_type: "depository",
      current_balance: 100,
      currency: "USD",
      name: "Provider Reset Account"
    )
    account_provider = AccountProvider.create!(account: account, provider: plaid_account)
    plaid_item.logo.attach(io: StringIO.new("logo"), filename: "logo.png", content_type: "image/png")
    attachment = plaid_item.logo.attachment

    plaid_provider = mock
    Provider::Registry.stubs(:plaid_provider_for_region).returns(plaid_provider)
    plaid_provider.expects(:remove_item).with(plaid_item.access_token).once

    result = Family::FinancialDataReset.new(family: @other_family, dry_run: false, confirmed: true).call

    assert_equal 0, result.after_counts.values.sum
    assert_not PlaidItem.exists?(plaid_item.id)
    assert_not PlaidAccount.exists?(plaid_account.id)
    assert_not AccountProvider.exists?(account_provider.id)
    assert_not ActiveStorage::Attachment.exists?(attachment.id)
  end

  test "destructive reset is idempotent" do
    first = Family::FinancialDataReset.new(user: @user, dry_run: false, confirmed: true).call
    second = Family::FinancialDataReset.new(user: @user, dry_run: false, confirmed: true).call

    assert_equal 0, first.after_counts.values.sum
    assert_equal 0, second.before_counts.values.sum
    assert_equal 0, second.after_counts.values.sum
  end

  private

    def reset_counts(family)
      Family::FinancialDataReset.new(family: family).call.before_counts
    end

    def create_extra_target_data!(family:, label:)
      safe_label = label.parameterize
      account = family.accounts.create!(
        name: "#{label} Checking",
        balance: 100,
        currency: "USD",
        accountable: Depository.new
      )
      transfer_account = family.accounts.create!(
        name: "#{label} Transfer Target",
        balance: 50,
        currency: "USD",
        accountable: Depository.new
      )
      share_user = family.users.create!(
        email: "#{safe_label}-#{SecureRandom.hex(4)}@example.com",
        password: "password123",
        password_confirmation: "password123",
        role: :member
      )
      account_share = account.account_shares.create!(user: share_user)
      category = family.categories.create!(
        name: "#{label} Category",
        color: "#407706",
        lucide_icon: "shapes"
      )
      tag = family.tags.create!(name: "#{label} Tag", color: "#12B76A")
      merchant = family.merchants.create!(name: "#{label} Merchant", color: "#12B76A")
      family_merchant_association = FamilyMerchantAssociation.create!(family: family, merchant: merchant)
      transaction = Transaction.create!(category: category, merchant: merchant)
      tagging = transaction.taggings.create!(tag: tag)
      entry = account.entries.create!(
        entryable: transaction,
        name: "#{label} transaction",
        date: Date.current,
        amount: 12,
        currency: "USD"
      )
      transaction.attachments.attach(io: StringIO.new("%PDF-1.4\nreceipt\n%%EOF\n"), filename: "#{safe_label}.pdf", content_type: "application/pdf")
      valuation = Valuation.create!
      valuation_entry = account.entries.create!(
        entryable: valuation,
        name: "#{label} valuation",
        date: Date.current - 1.day,
        amount: 100,
        currency: "USD"
      )
      trade = Trade.create!(security: securities(:aapl), qty: 1, price: 100, currency: "USD")
      trade_entry = account.entries.create!(
        entryable: trade,
        name: "#{label} trade",
        date: Date.current - 2.days,
        amount: 100,
        currency: "USD"
      )
      transfer = create_transfer!(source_account: account, target_account: transfer_account, label: label)
      rejected_transfer = create_rejected_transfer!(source_account: account, target_account: transfer_account, label: label)
      balance = account.balances.create!(date: Date.current, balance: 100, currency: "USD")
      holding = account.holdings.create!(
        security: securities(:aapl),
        date: Date.current,
        qty: 1,
        price: 100,
        amount: 100,
        currency: "USD"
      )
      recurring_transaction = family.recurring_transactions.create!(
        account: account,
        merchant: merchant,
        amount: 12,
        currency: "USD",
        expected_day_of_month: 1,
        last_occurrence_date: 1.month.ago.to_date,
        next_expected_date: 1.month.from_now.to_date,
        status: "active"
      )
      rule = family.rules.build(name: "#{label} Rule", resource_type: "transaction").tap do |rule|
        rule.conditions.build(condition_type: "transaction_name", operator: "like", value: label)
        rule.actions.build(action_type: "set_transaction_category", value: category.id)
        rule.save!
      end
      rule_run = rule.rule_runs.create!(
        execution_type: "manual",
        status: "success",
        transactions_queued: 1,
        transactions_processed: 1,
        transactions_modified: 1,
        executed_at: Time.current
      )
      budget_start = 10.years.from_now.to_date.beginning_of_month
      budget = family.budgets.create!(
        start_date: budget_start,
        end_date: budget_start.end_of_month,
        budgeted_spending: 100,
        expected_income: 200,
        currency: family.currency
      )
      budget_category = budget.budget_categories.create!(
        category: category,
        budgeted_spending: 50,
        currency: family.currency
      )
      import = family.imports.create!(type: "TransactionImport", status: "pending")
      import_row = import.rows.create!(
        source_row_number: 1,
        date: Date.current.strftime(import.date_format),
        amount: "12.00",
        currency: family.currency,
        name: "#{label} Imported Transaction"
      )
      import_mapping = Import::AccountMapping.create!(import: import, key: "#{label} Checking", mappable: account)
      family_export = family.family_exports.create!(status: "completed")
      family_export.export_file.attach(io: StringIO.new("zip"), filename: "#{safe_label}.zip", content_type: "application/zip")
      account_statement = create_account_statement!(family: family, account: account, label: label)
      plaid_item = family.plaid_items.create!(
        name: "#{label} Plaid Item",
        plaid_id: "plaid_item_#{safe_label}_#{family.id.delete("-")}",
        access_token: "access_#{safe_label}_#{family.id.delete("-")}",
        plaid_region: "us"
      )
      plaid_account = plaid_item.plaid_accounts.create!(
        plaid_id: "plaid_account_#{safe_label}",
        plaid_type: "depository",
        current_balance: 100,
        currency: family.currency,
        name: "#{label} Plaid Account"
      )
      account_provider = AccountProvider.create!(account: account, provider: plaid_account)
      plaid_item.logo.attach(io: StringIO.new("logo"), filename: "#{safe_label}.png", content_type: "image/png")
      family_sync = family.syncs.create!
      account_sync = account.syncs.create!
      provider_sync = plaid_item.syncs.create!

      {
        account: account,
        transfer_account: transfer_account,
        account_share: account_share,
        category: category,
        tag: tag,
        merchant: merchant,
        family_merchant_association: family_merchant_association,
        transaction: transaction,
        tagging: tagging,
        entry: entry,
        valuation: valuation,
        valuation_entry: valuation_entry,
        trade: trade,
        trade_entry: trade_entry,
        transfer: transfer,
        rejected_transfer: rejected_transfer,
        balance: balance,
        holding: holding,
        recurring_transaction: recurring_transaction,
        rule: rule,
        rule_action: rule.actions.first,
        rule_condition: rule.conditions.first,
        rule_run: rule_run,
        budget: budget,
        budget_category: budget_category,
        import: import,
        import_row: import_row,
        import_mapping: import_mapping,
        family_export: family_export,
        account_statement: account_statement,
        plaid_item: plaid_item,
        plaid_account: plaid_account,
        account_provider: account_provider,
        family_sync: family_sync,
        account_sync: account_sync,
        provider_sync: provider_sync
      }
    end

    def create_transfer!(source_account:, target_account:, label:)
      outflow = create_transaction_entry!(account: source_account, name: "#{label} transfer out", amount: 25)
      inflow = create_transaction_entry!(account: target_account, name: "#{label} transfer in", amount: -25)

      Transfer.create!(
        outflow_transaction: outflow.entryable,
        inflow_transaction: inflow.entryable,
        status: "confirmed"
      )
    end

    def create_rejected_transfer!(source_account:, target_account:, label:)
      outflow = create_transaction_entry!(account: source_account, name: "#{label} rejected transfer out", amount: 35)
      inflow = create_transaction_entry!(account: target_account, name: "#{label} rejected transfer in", amount: -35)

      RejectedTransfer.create!(
        outflow_transaction: outflow.entryable,
        inflow_transaction: inflow.entryable
      )
    end

    def create_transaction_entry!(account:, name:, amount:)
      transaction = Transaction.create!(kind: "funds_movement")

      account.entries.create!(
        entryable: transaction,
        name: name,
        date: Date.current - 3.days,
        amount: amount,
        currency: account.currency
      )
    end

    def create_account_statement!(family:, account:, label:)
      safe_label = label.parameterize
      content = "%PDF-1.4\n#{label}\n%%EOF\n"
      account_statement = family.account_statements.build(
        account: account,
        filename: "#{safe_label}.pdf",
        content_type: "application/pdf",
        byte_size: content.bytesize,
        checksum: Digest::MD5.base64digest(content),
        content_sha256: Digest::SHA256.hexdigest(content),
        source: :manual_upload,
        upload_status: :stored,
        review_status: :linked,
        currency: account.currency
      )
      account_statement.original_file.attach(
        io: StringIO.new(content),
        filename: "#{safe_label}.pdf",
        content_type: "application/pdf"
      )
      account_statement.save!
      account_statement
    end

    def reset_target_snapshot(records)
      records.transform_values { |record| record_snapshot(record) }.merge(
        attachments: [
          attachment_snapshot(records[:transaction], "attachments"),
          attachment_snapshot(records[:family_export], "export_file"),
          attachment_snapshot(records[:account_statement], "original_file"),
          attachment_snapshot(records[:plaid_item], "logo")
        ]
      )
    end

    def record_snapshot(record)
      record.class.where(id: record.id).pluck(*record.class.column_names).first
    end

    def attachment_snapshot(record, attachment_name)
      ActiveStorage::Attachment
        .where(record_type: record.class.name, record_id: record.id, name: attachment_name)
        .order(:id)
        .pluck(:id, :blob_id, :created_at)
    end
end
