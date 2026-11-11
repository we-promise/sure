class Setting::ProviderSecretBackfill
  # TODO: Maintainer: prefer an explicit task (like SimpleFIN's encryption backfill),
  # or upgrade/startup conversion? Confirm fail-closed behavior for marked ciphertext.
  def self.call(dry_run: true)
    counts = { candidates: 0, encrypted: 0, unchanged: 0, failed: 0 }
    keys = Provider::ConfigurationRegistry.secret_setting_keys
      .reject { |key| Setting.respond_to?("#{key}=") }
      .map { |key| "dynamic:#{key}" }

    Setting.where(var: keys).find_each do |row|
      begin
        row.with_lock do
          # with_lock reloads the row after acquiring its lock. Do not use a
          # value captured before locking: an administrator may have edited it.
          key = row.var.delete_prefix("dynamic:")
          value = row.value
          if Setting::DynamicSecret.marked?(value)
            Setting::DynamicSecret.decrypt(key, value)
            counts[:unchanged] += 1
          elsif value.blank?
            counts[:unchanged] += 1
          else
            counts[:candidates] += 1
            unless dry_run
              Setting[key] = value
              counts[:encrypted] += 1
            end
          end
        end
      rescue StandardError => error
        # Each row has its own transaction so an interrupted run can resume.
        counts[:failed] += 1
        Rails.logger.error("Provider secret backfill failed: id=#{row.id} var=#{row.var} error=#{error.class}")
      end
    end

    counts
  end
end
