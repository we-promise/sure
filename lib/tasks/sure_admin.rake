namespace :sure do
  namespace :admin do
    desc "Reset one user's family financial/import data while preserving users and auth records"
    task reset_financial_data: :environment do
      email = ENV["USER_EMAIL"].to_s.strip
      abort "USER_EMAIL is required." if email.blank?

      user = User.find_by(email: email)
      abort "No user found for USER_EMAIL=#{email.inspect}." unless user

      confirmed = ENV["CONFIRM_RESET_FINANCIAL_DATA"].to_s == "yes"
      dry_run = if ENV.key?("DRY_RUN")
        ActiveModel::Type::Boolean.new.cast(ENV["DRY_RUN"])
      else
        !confirmed
      end

      reset = Family::FinancialDataReset.new(
        user: user,
        dry_run: dry_run,
        confirmed: confirmed
      )

      puts "Resolved user: #{user.email} (id=#{user.id})"
      puts "Resolved family: #{user.family.name.presence || '(unnamed)'} (id=#{user.family.id})"
      puts "Mode: #{dry_run ? 'dry-run' : 'destructive'}"
      puts

      result = reset.call

      print_reset_counts("Before", result.before_counts)
      print_reset_counts("Deleted", result.deleted_counts)
      print_reset_counts("After", result.after_counts)
      puts
      puts(result.dry_run ? "Dry run only. No records were deleted." : "Financial data reset complete.")
    rescue Family::FinancialDataReset::ConfirmationRequiredError => e
      abort e.message
    end

    def print_reset_counts(label, counts)
      puts "#{label} counts:"
      Family::FinancialDataReset::COUNT_KEYS.each do |key|
        puts "  #{key}: #{counts.fetch(key, 0)}"
      end
    end
  end
end
