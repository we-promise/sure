class ValidateRefundOfForeignKey < ActiveRecord::Migration[8.1]
  def up
    validate_foreign_key :transactions, :transactions, column: :refund_of_id
  end

  def down
    # Validation can remain in place; rolling back the preceding migration
    # removes the foreign key together with the refund reference.
  end
end
