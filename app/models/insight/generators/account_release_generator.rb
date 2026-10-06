# Release reminders for locked money in the feed: a term
# deposit or similar account is released soon, has been released, or is
# about to renew by itself.
#
# Channel and lead time are set per person (User#account_release_channel),
# but the feed belongs to the family. So the generator only runs when at
# least one member wants reminders in the feed, uses the longest lead time
# among them, and only looks at accounts that count in one of those members'
# finances: an account none of them follows never reaches the feed. Like every
# other insight, a reminder is then seen by the whole family.
#
# The dedup key carries the account, the kind and the release date, so each
# reminder appears once per date and a new release date is a new reminder.
class Insight::Generators::AccountReleaseGenerator < Insight::Generator
  produces "account_release"

  MAX_INSIGHTS = 5

  def generate
    return [] if recipients.empty?

    reminders.first(MAX_INSIGHTS).map { |reminder| insight_for(reminder) }
  end

  private
    def recipients
      @recipients ||= family.users.with_preview_features.where(active: true).select(&:account_release_insights?)
    end

    def reminders
      today = Account.liquidity_today_for(family)
      lead_days = recipients.map(&:account_release_lead_days).max

      Account::ReleaseReminder.for(followed_accounts.to_a, date: today, lead_days: lead_days)
    end

    # Same rule as Account.included_in_finances_for, for several people in
    # one query: owned by one of them, or shared with one of them and counted
    # in their finances.
    def followed_accounts
      followed = family.accounts.left_joins(:account_shares).where(
        "accounts.owner_id IN (:ids) OR (account_shares.user_id IN (:ids) AND account_shares.include_in_finances = true)",
        ids: recipients.map(&:id)
      ).select(:id)

      Account::ReleaseReminder.candidates(family.accounts).where(id: followed)
    end

    def insight_for(reminder)
      account = reminder.account
      facts = {
        account: account.name,
        balance: Money.new(account.balance, account.currency).format,
        date: I18n.l(reminder.release_on, format: :long),
        days: reminder.days_until
      }

      build_insight(
        insight_type: "account_release",
        priority: reminder.kind == "upcoming" ? "medium" : "high",
        title: I18n.t("insights.titles.account_release.#{reminder.kind}", account: account.name),
        template_key: template_key(reminder),
        facts: facts,
        # Balance stays out: interest moving it a little must not resurface a
        # reminder the user has already acknowledged.
        metadata: {
          account_id: account.id,
          kind: reminder.kind,
          release_on: reminder.release_on.iso8601
        },
        dedup_key: "account_release:#{reminder.dedup_key}"
      )
    end

    def template_key(reminder)
      reminder.kind == "renewal" ? "account_release.renewal_notice" : "account_release.#{reminder.kind}"
    end
end
