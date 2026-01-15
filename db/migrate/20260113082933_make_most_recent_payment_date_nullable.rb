class MakeMostRecentPaymentDateNullable < ActiveRecord::Migration[7.2]
  def change
    change_column_null :installments, :most_recent_payment_date, true
  end
end
