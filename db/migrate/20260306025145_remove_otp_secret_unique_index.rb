class RemoveOtpSecretUniqueIndex < ActiveRecord::Migration[7.2]
  def change
    # Non-deterministic encryption produces different ciphertext for the same
    # value, so a unique index on otp_secret can never detect duplicates and
    # only wastes storage and write overhead.
    remove_index :users, :otp_secret, unique: true,
      where: "(otp_secret IS NOT NULL)",
      name: "index_users_on_otp_secret",
      if_exists: true
  end
end
