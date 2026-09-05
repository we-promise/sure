class AddDailyAccrualMetadataToLoanAmortizations < ActiveRecord::Migration[7.2]
  def change
    add_column :loan_amortizations, :algorithm_version, :integer, null: false, default: 2
    add_column :loan_amortizations, :generated_at, :datetime, null: false, default: -> { "CURRENT_TIMESTAMP" }

    add_index :loan_amortizations, [ :loan_id, :algorithm_version ],
              name: "index_loan_amortizations_on_loan_id_and_algorithm_version"
  end
end
