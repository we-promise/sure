# Several providers used to build default account names around the full
# account number, e.g. "TFSA (12345678)" or "Fio banka 2400222222". Those
# names show up in lists, reports, exports, the API and the assistant. New
# names keep only the last 4 characters; this rewrites the existing ones.
#
# Only the exact full number is replaced, wherever it appears on its own in a
# provider record's or linked account's name (a longer number that merely
# contains it is left untouched), so any wording a user added is kept and
# renamed accounts that no longer carry the number are left alone. An
# Interactive Brokers provider record named after the bare number gets the
# default name.
class MaskAccountNumbersInGeneratedAccountNames < ActiveRecord::Migration[8.1]
  PREFIX = "•••"
  BATCH_SIZE = 500

  # provider account table => [ provider_type, identifier column, name style ]
  # (:ibkr records may be named after the bare account id)
  PROVIDERS = {
    "questrade_accounts" => [ "QuestradeAccount", "questrade_account_id", :default ],
    "indexa_capital_accounts" => [ "IndexaCapitalAccount", "indexa_capital_account_id", :default ],
    "ibkr_accounts" => [ "IbkrAccount", "ibkr_account_id", :ibkr ],
    "trade_republic_accounts" => [ "TradeRepublicAccount", "trade_republic_account_id", :default ],
    "trading212_accounts" => [ "Trading212Account", "trading212_account_id", :default ],
    "fio_accounts" => [ "FioAccount", "fio_account_id", :default ]
  }.freeze

  def up
    PROVIDERS.each do |table, (provider_type, id_column, style)|
      next unless table_exists?(table) && column_exists?(table, id_column)

      last_id = nil

      loop do
        rows = provider_batch(table, provider_type, id_column, last_id)
        break if rows.empty?

        rows.group_by(&:first).each do |provider_id, provider_rows|
          _, raw_identifier, provider_name = provider_rows.first
          identifier = raw_identifier.to_s.sub(/\A(cash|crypto):/, "")
          next if identifier.length <= 4

          if (new_name = mask_name(provider_name, identifier, style))
            execute "UPDATE #{quote_table_name(table)} SET name = #{connection.quote(new_name)} WHERE id = #{connection.quote(provider_id)}"
          end

          provider_rows.each do |_, _, _, account_id, account_name|
            next unless account_id && (new_name = mask_name(account_name, identifier, style))

            execute "UPDATE accounts SET name = #{connection.quote(new_name)} WHERE id = #{connection.quote(account_id)}"
          end
        end

        last_id = rows.last.first
      end
    end
  end

  def down
    # The full numbers are still stored on the provider accounts and the next
    # sync rebuilds provider names, but a user's own account names are not
    # restored to show the full number again.
  end

  private

    def batch_size
      BATCH_SIZE
    end

    # One query per batch of provider rows, each joined to its linked
    # accounts: [provider id, identifier, provider name, account id, account name].
    def provider_batch(table, provider_type, id_column, last_id)
      after = last_id ? "AND id > #{connection.quote(last_id)}" : ""

      select_rows(<<~SQL)
        SELECT providers.id, providers.identifier, providers.name, accounts.id, accounts.name
        FROM (
          SELECT id, #{quote_column_name(id_column)} AS identifier, name FROM #{quote_table_name(table)}
          WHERE #{quote_column_name(id_column)} IS NOT NULL #{after}
          ORDER BY id LIMIT #{batch_size}
        ) providers
        LEFT JOIN account_providers ON account_providers.provider_id = providers.id
          AND account_providers.provider_type = #{connection.quote(provider_type)}
        LEFT JOIN accounts ON accounts.id = account_providers.account_id
        ORDER BY providers.id
      SQL
    end

    def mask_name(name, identifier, style)
      return nil if name.blank?

      masked = "#{PREFIX}#{identifier.last(4)}"
      return "Interactive Brokers (#{masked})" if style == :ibkr && name == identifier

      pattern = /(?<![[:alnum:]])#{Regexp.escape(identifier)}(?![[:alnum:]])/
      name.gsub(pattern, masked) if name.match?(pattern)
    end
end
