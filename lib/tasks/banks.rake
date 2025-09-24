namespace :banks do
  desc "Backfill Wise items to generic BankConnections (copy-only, no deletes)"
  task backfill_wise_to_bank_connections: :environment do
    count = 0
    WiseItem.find_each do |wi|
      begin
        creds = { api_key: wi.api_key }
        conn = wi.family.bank_connections.find_or_create_by!(provider: :wise, name: wi.name) do |bc|
          bc.credentials = creds.to_json
        end

        wi.wise_accounts.find_each do |wa|
          ext = conn.bank_external_accounts.find_or_initialize_by(provider_account_id: wa.account_id)
          ext.name = wa.name
          ext.currency = wa.currency
          ext.current_balance = wa.current_balance
          ext.available_balance = wa.available_balance
          ext.balance_date = wa.balance_date
          ext.raw_payload = wa.raw_payload
          ext.raw_transactions_payload = wa.raw_transactions_payload
          ext.save!

          # Link internal Account if present
          if wa.account.present?
            wa.account.update!(bank_external_account_id: ext.id)
          end
        end
        count += 1
      rescue => e
        Rails.logger.error("Backfill error for WiseItem #{wi.id}: #{e.message}")
      end
    end
    puts "Backfilled #{count} Wise connections into BankConnections"
  end
end

