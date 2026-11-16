# Base class for weekly cleanup detectors. Each detector answers one question
# about the family's books over a fixed window and returns a Finding (or nil
# when everything is clean). Detectors are strictly read-only: they SELECT and
# present, they never mutate.
class WeeklyCleanup::Detector
  WINDOW = 7.days
  MAX_SAMPLES = 5

  Finding = Data.define(:key, :heading, :count, :samples)

  def self.registry
    [
      WeeklyCleanup::Detectors::UncategorizedTransactions,
      WeeklyCleanup::Detectors::StaleImports,
      WeeklyCleanup::Detectors::ProviderDataGaps,
      WeeklyCleanup::Detectors::MissingMerchantInfo,
      WeeklyCleanup::Detectors::DuplicateImportedEntries,
      WeeklyCleanup::Detectors::MissingContext,
      WeeklyCleanup::Detectors::MerchantDuplicates
    ]
  end

  def self.key
    name.demodulize.underscore
  end

  # `user` scopes account-level findings to what that admin can access
  # (Account.accessible_by). Without one, findings cover every family account.
  def initialize(family, user: nil)
    @family = family
    @user = user
  end

  # Returns a Finding, or nil when the detector found nothing worth reporting.
  def generate
    raise NotImplementedError
  end

  private
    attr_reader :family, :user

    # The family's calendar date, not the job's (UTC) one.
    def today
      family.local_date
    end

    def window_start
      today - WINDOW.in_days.to_i
    end

    def accounts
      user ? user.accessible_accounts : family.accounts
    end

    def entries
      Entry.where(account_id: accounts.select(:id))
    end

    def finding(heading:, count:, samples: [])
      return nil if count.zero?

      Finding.new(key: self.class.key, heading: heading, count: count, samples: samples.first(MAX_SAMPLES))
    end

    # Recent standard (non-transfer, non-excluded) purchase/refund transactions
    # joined to their entries — the base relation most detectors filter further.
    def recent_standard_entries(since: window_start)
      entries
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id")
        .where(entryable_type: "Transaction", excluded: false)
        .where(transactions: { kind: "standard" })
        .where("entries.date >= ? AND entries.date <= ?", since, today)
    end
end
