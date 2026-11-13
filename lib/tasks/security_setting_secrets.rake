# frozen_string_literal: true

namespace :security do
  desc "Re-encrypt encrypted settings (API keys, tokens) after a SECRET_KEY_BASE change. " \
       "Reads the previous value from OLD_SECRET_KEY_BASE. Args: dry_run (default 1)"
  task :rotate_setting_secrets, [ :dry_run ] => :environment do |_, args|
    raw_dry = args[:dry_run].presence || ENV["DRY_RUN"].presence
    dry_run = !%w[0 false no n].include?(raw_dry.to_s.strip.downcase)

    old_secret_key_base = ENV["OLD_SECRET_KEY_BASE"].to_s.strip
    if old_secret_key_base.blank?
      puts({
        ok: false,
        error: "old_secret_key_base_missing",
        message: "Set OLD_SECRET_KEY_BASE to the SECRET_KEY_BASE value the settings were saved with."
      }.to_json)
      exit 1
    end

    if old_secret_key_base == Rails.application.secret_key_base
      puts({
        ok: false,
        error: "secret_key_base_unchanged",
        message: "OLD_SECRET_KEY_BASE equals the current SECRET_KEY_BASE. Change SECRET_KEY_BASE first, then run this task."
      }.to_json)
      exit 1
    end

    results = Setting.reencrypt_secrets_from(old_secret_key_base, dry_run: dry_run)
    not_decryptable = results.select { |_, status| status == :not_decryptable }.keys
    moved = results.values.intersect?(%i[reencrypted would_reencrypt])

    # Nothing decrypted with the old value, but some fields need it: the value
    # is most likely mistyped. Report that instead of telling the operator to
    # re-enter every key.
    if not_decryptable.any? && !moved
      puts({
        ok: false,
        error: "old_secret_key_base_did_not_match",
        message: "No setting decrypts with OLD_SECRET_KEY_BASE. Check the value, or re-enter the listed keys if it is correct.",
        results: results,
        not_decryptable: not_decryptable
      }.to_json)
      exit 1
    end

    puts({
      ok: true,
      dry_run: dry_run,
      results: results,
      not_decryptable: not_decryptable
    }.to_json)
  end
end
