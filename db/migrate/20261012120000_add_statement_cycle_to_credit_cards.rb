class AddStatementCycleToCreditCards < ActiveRecord::Migration[8.1]
  def change
    add_column :credit_cards, :statement_close_day, :integer
    add_column :credit_cards, :due_day, :integer

    add_check_constraint :credit_cards,
                         "statement_close_day BETWEEN 1 AND 31",
                         name: "chk_credit_cards_statement_close_day"
    add_check_constraint :credit_cards,
                         "due_day BETWEEN 1 AND 31",
                         name: "chk_credit_cards_due_day"
  end
end
