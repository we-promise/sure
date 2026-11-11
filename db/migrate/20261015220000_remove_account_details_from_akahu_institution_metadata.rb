# Akahu used to copy the full bank account number and the account holder's
# name into institution_metadata, a plain jsonb column. Nothing reads either
# key: the account number lives in formatted_account (now encrypted) and the
# raw payload, and the holder name is not shown anywhere. Strip both from
# existing rows so the personal data no longer sits there in plaintext.
class RemoveAccountDetailsFromAkahuInstitutionMetadata < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      UPDATE akahu_accounts
      SET institution_metadata = institution_metadata - 'account_number' - 'holder'
      WHERE institution_metadata ?| array['account_number', 'holder']
    SQL
  end

  def down
    # The removed values are still in raw_payload; the next sync does not
    # write them back, so there is nothing to restore here.
  end
end
