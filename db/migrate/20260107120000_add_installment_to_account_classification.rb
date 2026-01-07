class AddInstallmentToAccountClassification < ActiveRecord::Migration[7.2]
  def up
    remove_column :accounts, :classification, :virtual

    change_table :accounts do |t|
      t.virtual(
        :classification,
        type: :string,
        stored: true,
        as: <<-SQL
          CASE
            WHEN accountable_type IN ('Loan', 'CreditCard', 'OtherLiability', 'Installment')
            THEN 'liability'
            ELSE 'asset'
          END
        SQL
      )
    end
  end

  def down
    remove_column :accounts, :classification, :virtual

    change_table :accounts do |t|
      t.virtual(
        :classification,
        type: :string,
        stored: true,
        as: <<-SQL
          CASE
            WHEN accountable_type IN ('Loan', 'CreditCard', 'OtherLiability')
            THEN 'liability'
            ELSE 'asset'
          END
        SQL
      )
    end
  end
end
