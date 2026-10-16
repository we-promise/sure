# Several providers used to build default account names around the full
# account number, e.g. "TFSA (12345678)" or "Fio banka 2400222222". Those
# names show up in lists, reports, exports, the API and the assistant. New
# names keep only the last 4 characters; this rewrites the existing ones.
#
# Only the exact full number is replaced, and only where a name still ends
# with it ("(<number>)", for Fio "... Fio banka <number>", for an Interactive
# Brokers provider record the bare number), so any wording a
# user added is kept and renamed accounts that no longer carry the number are
# left alone.
class MaskAccountNumbersInGeneratedAccountNames < ActiveRecord::Migration[8.1]
  PREFIX = "•••"

  # provider account table => [ provider_type, identifier column, name style ]
  PROVIDERS = {
    "questrade_accounts" => [ "QuestradeAccount", "questrade_account_id", :parenthesized ],
    "indexa_capital_accounts" => [ "IndexaCapitalAccount", "indexa_capital_account_id", :parenthesized ],
    "ibkr_accounts" => [ "IbkrAccount", "ibkr_account_id", :ibkr ],
    "trade_republic_accounts" => [ "TradeRepublicAccount", "trade_republic_account_id", :parenthesized ],
    "trading212_accounts" => [ "Trading212Account", "trading212_account_id", :parenthesized ],
    "fio_accounts" => [ "FioAccount", "fio_account_id", :fio ]
  }.freeze

  FIO_INSTITUTION_NAME = "Fio banka"

  def up
    PROVIDERS.each do |table, (provider_type, id_column, style)|
      next unless table_exists?(table) && column_exists?(table, id_column)

      rows = select_rows(<<~SQL)
        SELECT id, #{quote_column_name(id_column)}, name FROM #{quote_table_name(table)}
        WHERE #{quote_column_name(id_column)} IS NOT NULL
      SQL

      rows.each do |provider_id, raw_identifier, provider_name|
        identifier = raw_identifier.to_s.sub(/\A(cash|crypto):/, "")
        next if identifier.length <= 4

        masked_name = ->(name) { mask_name(name, identifier, style) }

        if (new_name = masked_name.call(provider_name))
          execute "UPDATE #{quote_table_name(table)} SET name = #{connection.quote(new_name)} WHERE id = #{connection.quote(provider_id)}"
        end

        account_rows = select_rows(<<~SQL)
          SELECT accounts.id, accounts.name FROM accounts
          INNER JOIN account_providers ON account_providers.account_id = accounts.id
          WHERE account_providers.provider_type = #{connection.quote(provider_type)}
            AND account_providers.provider_id = #{connection.quote(provider_id)}
        SQL

        account_rows.each do |account_id, account_name|
          next unless (new_name = masked_name.call(account_name))

          execute "UPDATE accounts SET name = #{connection.quote(new_name)} WHERE id = #{connection.quote(account_id)}"
        end
      end
    end
  end

  def down
    # The full numbers are still stored on the provider accounts and the next
    # sync rebuilds provider names, but a user's own account names are not
    # restored to show the full number again.
  end

  private

    def mask_name(name, identifier, style)
      return nil if name.blank?

      masked = "#{PREFIX}#{identifier.last(4)}"

      case style
      when :parenthesized
        suffix = "(#{identifier})"
        name.end_with?(suffix) ? "#{name.delete_suffix(suffix)}(#{masked})" : nil
      when :ibkr
        # The provider record was named after the bare account id; the linked
        # account got "Interactive Brokers (<id>)".
        if name == identifier
          "Interactive Brokers (#{masked})"
        elsif name.end_with?("(#{identifier})")
          "#{name.delete_suffix("(#{identifier})")}(#{masked})"
        end
      when :fio
        suffix = "#{FIO_INSTITUTION_NAME} #{identifier}"
        name.end_with?(suffix) ? "#{name.delete_suffix(suffix)}#{FIO_INSTITUTION_NAME} #{masked}" : nil
      end
    end
end
