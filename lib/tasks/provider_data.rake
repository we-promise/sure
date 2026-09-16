namespace :provider_data do
  desc "Dispose one unowned historical Questrade activity flag after old workers drain (FAMILY_ID, LEGACY_ACCOUNT_ID required)"
  task dispose_questrade_activity_flag: :environment do
    family = Family.find(ENV.fetch("FAMILY_ID"))
    source = QuestradeAccount.joins(:questrade_item).where(questrade_items: { family_id: family.id }).find(ENV.fetch("LEGACY_ACCOUNT_ID"))
    receipt = QuestradeAccount::ActivitiesRequest.dispose_unowned!(source, family: family)
    puts "Recorded unknown historical request #{receipt.request_id}; no successful fetch or financial change was recorded."
  end

  desc "Activate one fully prepared, native-ready connection with a reviewed cutover contract (PROVIDER, FAMILY_ID, LEGACY_ITEM_ID required; PAGE_SIZE must match preparation)"
  task cutover: :environment do
    family = Family.find(ENV.fetch("FAMILY_ID"))
    result = Provider::AccountData::MigrationCutover.new(provider_key: ENV.fetch("PROVIDER"),
      legacy_item_id: ENV.fetch("LEGACY_ITEM_ID"), family: family,
      page_size: Integer(ENV.fetch("PAGE_SIZE", "100"))).call
    puts JSON.pretty_generate(result.to_h)
  end

  desc "Inspect account source ownership without modifying data (FAMILY_ID and ACCOUNT_ID required)"
  task account_sources: :environment do
    account = Account.find_by!(id: ENV.fetch("ACCOUNT_ID"), family_id: ENV.fetch("FAMILY_ID"))
    captured = Account::Destruction::Sources.capture(account: account)
    puts JSON.pretty_generate({
      family_id: captured.family_id, account_id: captured.root_account_id,
      affected_account_ids: captured.account_ids, legacy_items: captured.legacy_items,
      connection_ids: captured.connection_ids, external_ids: captured.external_ids,
      migration_control_ids: captured.control_ids, statement_ids: captured.document_ids,
      import_ids: captured.import_ids, deletion_authorized: false
    })
  rescue Account::Destruction::Sources::InvalidGraph => error
    abort "Account source inventory is unresolved: #{error.message}"
  end

  desc "Report legacy connection counts and shared migration states"
  task status: :environment do
    Provider::AccountData::MigrationManifest.all.each do |manifest|
      source_count = manifest.item_type.constantize.count
      states = ProviderMigrationControl.where(provider_key: manifest.provider_key).group(:state).count
      puts "#{manifest.provider_key}: legacy_rows=#{source_count} states=#{states.sort.to_h.to_json}"
    end
  end

  desc "Copy and verify provider data into disabled shared storage (PROVIDER/FAMILY_ID optional)"
  task copy: :environment do
    manifests = if ENV["PROVIDER"].present?
      [ Provider::AccountData::MigrationManifest.for(ENV.fetch("PROVIDER")) ]
    else
      Provider::AccountData::MigrationManifest.all
    end
    count = 0
    manifests.each do |manifest|
      sources = manifest.item_type.constantize.all
      sources = sources.where(family_id: ENV["FAMILY_ID"]) if ENV["FAMILY_ID"].present?
      sources.find_each do |item|
        ProviderDataMigrationJob.perform_later(provider_key: manifest.provider_key, legacy_item_id: item.id, family_id: item.family_id)
        count += 1
      end
    end
    puts "Scheduled #{count} connection copies. Legacy providers remain authoritative."
  end

  desc "Index retained account archive ownership (FAMILY_ID required; AFTER_ID/LIMIT optional)"
  task index_retained_accounts: :environment do
    family_id = ENV.fetch("FAMILY_ID")
    index = Provider::AccountData::RetainedAccountIndex
    page = index.backfill_page(family_id: family_id, after_id: ENV["AFTER_ID"].presence,
      limit: Integer(ENV.fetch("LIMIT", "25")))
    puts "Indexed #{page.processed} archive versions. Next cursor: #{page.next_cursor || 'none'}"
    unresolved = index.unindexed_chunks(family_id: family_id).exists?
    puts "Unindexed account archive chunks remain: #{unresolved}"
    abort "Retained account archive inventory is incomplete; inspect unresolved chunks." if page.complete && unresolved
  end

  desc "Index original historical command bindings (FAMILY_ID required; AFTER_ID/LIMIT optional)"
  task index_historical_bindings: :environment do
    family_id = ENV.fetch("FAMILY_ID")
    index = Ingestion::HistoricalBalances::SourceBinding
    page = index.backfill_page(family_id: family_id, after_id: ENV["AFTER_ID"].presence,
      limit: Integer(ENV.fetch("LIMIT", "25")))
    puts "Indexed #{page.processed} historical commands. Next cursor: #{page.next_cursor || 'none'}"
    if page.complete
      begin
        index.assert_complete_for!(family_id: family_id)
      rescue Ingestion::HistoricalBalances::SourceBinding::Incomplete
        abort "Historical command inventory is incomplete; unresolved captures remain before or beyond this page."
      end
    end
  end

  desc "Index original generation account bindings (FAMILY_ID required; AFTER_ID/LIMIT optional)"
  task index_generation_accounts: :environment do
    family_id = ENV.fetch("FAMILY_ID")
    index = Provider::AccountData::GenerationAccountIndex
    page = index.backfill_page(family_id: family_id, after_id: ENV["AFTER_ID"].presence,
      limit: Integer(ENV.fetch("LIMIT", "25")))
    puts "Indexed #{page.processed} generation captures. Next cursor: #{page.next_cursor || 'none'}"
    if page.complete
      begin
        index.assert_complete_for!(family_id: family_id)
      rescue Provider::AccountData::GenerationAccountIndex::Incomplete
        abort "Generation account inventory is incomplete; unresolved captures remain before or beyond this page."
      end
    end
  end
end
