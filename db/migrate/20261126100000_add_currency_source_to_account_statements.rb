# Where a statement's currency came from: the document, the linked account,
# the user, or the family's default. Only a family default is replaced by a
# currency the document names later. Filled in by the next migration.
class AddCurrencySourceToAccountStatements < ActiveRecord::Migration[8.1]
  def change
    add_column :account_statements, :currency_source, :string
    add_check_constraint :account_statements,
                         "currency_source IN ('document', 'account', 'user', 'family_default')",
                         name: "chk_account_statements_currency_source"
  end
end
