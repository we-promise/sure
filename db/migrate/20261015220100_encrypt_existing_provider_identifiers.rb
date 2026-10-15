# EnableBankingAccount#iban, EnableBankingItem#last_psu_ip,
# AkahuAccount#formatted_account and LunchflowAccount#raw_holdings_payload are
# encrypted from this release on. Rows synced earlier still hold plaintext,
# and once the attribute is encrypted, reading plaintext raises unless the
# instance opted into support_unencrypted_data. The Enable Banking sync reads
# last_psu_ip and the Lunch Flow holdings import reads its payload, so those
# rows would break the next sync. Encrypt them now instead of relying on a
# later security:backfill_encryption run.
#
# Does nothing when encryption is not configured: the attributes are then not
# encrypted at all, and security:backfill_encryption covers them once keys are
# set.
class EncryptExistingProviderIdentifiers < ActiveRecord::Migration[8.1]
  COLUMNS = {
    "EnableBankingAccount" => %w[iban],
    "EnableBankingItem" => %w[last_psu_ip],
    "AkahuAccount" => %w[formatted_account],
    "LunchflowAccount" => %w[raw_holdings_payload]
  }.freeze

  BATCH_SIZE = 500

  def up
    COLUMNS.each do |model_name, columns|
      model = model_name.constantize
      next unless model.encryption_ready?

      model.reset_column_information
      columns.each { |column| encrypt_plaintext(model, column) }
    end
  end

  def down
    # Encrypted values stay readable; nothing to undo.
  end

  private

    def encrypt_plaintext(model, column)
      json = %i[json jsonb].include?(model.columns_hash[column].type)
      quoted = connection.quote_column_name(column)
      last_id = nil

      # Paged by id so large payload columns are not loaded all at once.
      loop do
        after = last_id ? "AND id > #{connection.quote(last_id)}" : ""
        rows = connection.select_rows(<<~SQL)
          SELECT id, #{quoted}::text FROM #{model.quoted_table_name}
          WHERE #{quoted} IS NOT NULL #{after}
          ORDER BY id LIMIT #{BATCH_SIZE}
        SQL
        break if rows.empty?

        rows.each do |id, raw|
          next if ActiveRecord::Encryption.encryptor.encrypted?(raw)

          value = json ? JSON.parse(raw) : raw
          # update_all casts through the encrypted attribute type, so the
          # value is written as ciphertext.
          model.unscoped.where(id: id).update_all(column => value)
        end
        last_id = rows.last.first
      end
    end
end
