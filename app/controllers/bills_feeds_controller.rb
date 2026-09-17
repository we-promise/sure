# Read-only iCal feed of upcoming bill occurrences, so calendar apps can
# subscribe (an entire third-party product exists to do this for a
# competitor). Token-authenticated and sessionless, and deliberately
# obligations only -- no balances, no accounts.
#
# The token is signed and names the MEMBER, not the family: sharing is per
# account, so each member's feed carries only the bills they can reach in
# the app. The signature binds a digest of the family's stored feed secret,
# which is how resetting that secret still revokes every previously shared
# URL in one stroke.
class BillsFeedsController < ApplicationController
  skip_authentication

  HORIZON_DAYS = 90

  def show
    payload = Family.bills_feed_verifier.verified(params[:token].to_s)
    user_id, stamp = payload if payload.is_a?(Array)
    user = User.find_by(id: user_id)
    family = user&.family
    raise ActiveRecord::RecordNotFound unless family && stamp.present? && stamp == family.bills_feed_stamp

    # Preview-gated like every other bills surface. Sessionless, so the gate
    # reads the member the token names: opting out of preview features (or the
    # family switching recurring off) kills retained URLs immediately, not
    # only after a token reset.
    raise ActiveRecord::RecordNotFound unless user.preview_features_enabled? && !family.recurring_transactions_disabled?

    occurrences = family.recurring_occurrences
                        .open_status
                        .joins(:recurring_transaction)
                        .merge(RecurringTransaction.accessible_by(user))
                        .where(recurring_transactions: { status: :active })
                        .where("recurring_transactions.amount > 0")
                        .where(due_on: Date.current..(Date.current + HORIZON_DAYS))
                        .includes(:recurring_transaction)
                        .order(:due_on)

    I18n.with_locale(family.locale.presence || I18n.default_locale) do
      render plain: to_ical(occurrences), content_type: "text/calendar"
    end
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  private
    def to_ical(occurrences)
      events = occurrences.map do |occurrence|
        series = occurrence.recurring_transaction
        amount = Money.new(occurrence.resolved_expected_amount, occurrence.currency).format

        <<~EVENT
          BEGIN:VEVENT
          UID:#{occurrence.id}@sure-bills
          DTSTAMP:#{Time.current.utc.strftime("%Y%m%dT%H%M%SZ")}
          DTSTART;VALUE=DATE:#{occurrence.effective_due_on.strftime("%Y%m%d")}
          SUMMARY:#{escape_ical(series.display_name)} (#{escape_ical(amount)})
          END:VEVENT
        EVENT
      end

      <<~ICAL
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Sure//Bills//EN
        X-WR-CALNAME:#{escape_ical(I18n.t("bills.feed.calendar_name"))}
        #{events.join}
        END:VCALENDAR
      ICAL
    end

    def escape_ical(text)
      text.to_s.gsub("\\", "\\\\\\\\").gsub(",", "\\,").gsub(";", "\\;").gsub("\n", " ")
    end
end
