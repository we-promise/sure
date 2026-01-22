class AccountImport < Import
  OpeningBalanceError = Class.new(StandardError)

  def import!
    transaction do
      rows.each do |row|
        mapping = mappings.account_types.find_by(key: row.entity_type)
        accountable_class = mapping.value.constantize

        account = family.accounts.build(
          name: row.name,
          balance: row.amount.to_d,
          currency: row.currency,
          accountable: accountable_class.new,
          import: self
        )

        account.save!

        manager = Account::OpeningBalanceManager.new(account)

        # Parse date if provided, otherwise use default
        balance_date = if row.date.present?
          begin
            Date.strptime(row.date, date_format)
          rescue ArgumentError => e
            raise OpeningBalanceError, "Invalid date format for '#{row.date}': #{e.message}"
          end
        else
          nil
        end

        result = manager.set_opening_balance(balance: row.amount.to_d, date: balance_date)

        # Re-raise since we should never have an error here
        if result.error
          raise OpeningBalanceError, result.error
        end
      end
    end
  end

  def mapping_steps
    [ Import::AccountTypeMapping ]
  end

  def required_column_keys
    %i[name amount]
  end

  def column_keys
    %i[entity_type name amount currency date]
  end

  def dry_run
    {
      accounts: rows_count
    }
  end

  def csv_template
    template = <<-CSV
      Account type*,Name*,Balance*,Currency,Balance Date
      Checking,Main Checking Account,1000.00,USD,01/01/2024
      Savings,Emergency Fund,5000.00,USD,01/15/2024
      Credit Card,Rewards Card,-500.00,USD,02/01/2024
    CSV

    CSV.parse(template, headers: true)
  end

  def max_row_count
    50
  end
end
