# EnableBankingItem#last_psu_ip, AkahuAccount#formatted_account and
# LunchflowAccount#raw_holdings_payload are encrypted from this release on.
# Rows synced earlier still hold plaintext. The attributes keep reading it
# (support_unencrypted_data), so nothing breaks, but the data would stay
# plaintext at rest until someone runs security:backfill_encryption. Encrypt
# it now instead.
#
# Does nothing when encryption is not configured: the attributes are then not
# encrypted at all, and security:backfill_encryption covers them once keys are
# set.
class EncryptExistingProviderIdentifiers < ActiveRecord::Migration[8.1]
  # Each row commits on its own, so a running sync never waits on locks held
  # until the whole migration finishes. A rerun after a partial run is safe:
  # rows already done are skipped.
  disable_ddl_transaction!

  COLUMNS = {
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

  # Writes the values back as plaintext, so code from before this release can
  # read them again after a rollback. The current code reads both forms.
  def down
    COLUMNS.each do |model_name, columns|
      model = model_name.constantize
      next unless model.encryption_ready?

      model.reset_column_information
      columns.each { |column| decrypt_ciphertext(model, column) }
    end
  end

  private

    def encrypt_plaintext(model, column)
      json = json_column?(model, column)

      each_stored_value(model, column) do |id, raw|
        next if ActiveRecord::Encryption.encryptor.encrypted?(raw)

        value = json ? JSON.parse(raw) : raw
        # update_all casts through the encrypted attribute type, so the
        # value is written as ciphertext.
        unchanged(model, column, id, raw).update_all(column => value)
      end
    end

    def decrypt_ciphertext(model, column)
      json = json_column?(model, column)

      each_stored_value(model, column) do |id, raw|
        next unless ActiveRecord::Encryption.encryptor.encrypted?(raw)

        plaintext = ActiveRecord::Encryption.encryptor.decrypt(raw)
        # Plain SQL, so the value is not encrypted again on the way in.
        unchanged(model, column, id, raw).update_all(
          [ "#{connection.quote_column_name(column)} = ?#{"::jsonb" if json}", plaintext ]
        )
      end
    end

    # Paged by id so large payload columns are not loaded all at once.
    def each_stored_value(model, column)
      quoted = connection.quote_column_name(column)
      last_id = nil

      loop do
        after = last_id ? "AND id > #{connection.quote(last_id)}" : ""
        rows = connection.select_rows(<<~SQL)
          SELECT id, #{quoted}::text FROM #{model.quoted_table_name}
          WHERE #{quoted} IS NOT NULL #{after}
          ORDER BY id LIMIT #{BATCH_SIZE}
        SQL
        break if rows.empty?

        rows.each { |id, raw| yield id, raw }
        last_id = rows.last.first
      end
    end

    # Skips the row if a sync wrote a new value since it was read, instead of
    # overwriting that value with the old one.
    def unchanged(model, column, id, raw)
      model.unscoped.where(id: id).where("#{connection.quote_column_name(column)}::text = ?", raw)
    end

    def json_column?(model, column)
      %i[json jsonb].include?(model.columns_hash[column].type)
    end
end
