class ConvertOtpBackupCodesToText < ActiveRecord::Migration[7.2]
  def up
    add_column :users, :otp_backup_codes_text, :text

    execute <<~SQL
      UPDATE users
      SET otp_backup_codes_text = array_to_json(otp_backup_codes)::text
      WHERE otp_backup_codes IS NOT NULL
        AND array_length(otp_backup_codes, 1) > 0
    SQL

    remove_column :users, :otp_backup_codes
    rename_column :users, :otp_backup_codes_text, :otp_backup_codes
  end

  def down
    add_column :users, :otp_backup_codes_array, :string, array: true, default: []

    execute <<~SQL
      UPDATE users
      SET otp_backup_codes_array = ARRAY(
        SELECT json_array_elements_text(otp_backup_codes::json)
      )
      WHERE otp_backup_codes IS NOT NULL
        AND otp_backup_codes != ''
        AND otp_backup_codes != '[]'
    SQL

    remove_column :users, :otp_backup_codes
    rename_column :users, :otp_backup_codes_array, :otp_backup_codes
  end
end
