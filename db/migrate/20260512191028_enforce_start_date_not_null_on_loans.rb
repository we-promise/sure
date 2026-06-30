class EnforceStartDateNotNullOnLoans < ActiveRecord::Migration[7.2]
  def up
    null_count = execute("SELECT COUNT(*) FROM loans WHERE start_date IS NULL")
                   .first["count"].to_i

    if null_count > 0
      raise "Cannot enforce NOT NULL: #{null_count} loans still have NULL start_date"
    end

    change_column_null :loans, :start_date, false
  end

  def down
    change_column_null :loans, :start_date, true
  end
end
