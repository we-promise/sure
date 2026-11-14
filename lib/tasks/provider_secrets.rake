namespace :provider_secrets do
  desc "Encrypt stored dynamic provider secrets (count-only unless APPLY=true)"
  task backfill: :environment do
    counts = Setting::ProviderSecretBackfill.call(dry_run: ENV["APPLY"] != "true")
    puts counts.map { |key, count| "#{key}=#{count}" }.join(" ")
    abort "Provider secret backfill encountered failures" if counts[:failed].positive?
  end
end
