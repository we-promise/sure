class EncryptExistingImportsRawFileStr < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  def up
    Import.unscoped.find_in_batches do |batch|
      ActiveRecord::Base.transaction do
        batch.each do |import|
          import.encrypt
          import.save!
        end
      end
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
