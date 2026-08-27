# Read-only iCal feed of upcoming bill occurrences, so calendar apps can
# subscribe (an entire third-party product exists to do this for a
# competitor). Token-authenticated: the URL carries a stored random secret,
# works without a session, and deliberately contains obligations only -- no
# balances, no accounts. Resetting the token revokes every previously
# shared URL.
class BillsFeedsController < ApplicationController
  skip_authentication

  HORIZON_DAYS = 90

  def show
    family = Family.where.not(bills_feed_token: nil).find_by!(bills_feed_token: params[:token].to_s)

    occurrences = family.recurring_occurrences
                        .open_status
                        .joins(:recurring_transaction)
                        .where(recurring_transactions: { status: :active })
                        .where("recurring_transactions.amount > 0")
                        .where(due_on: Date.current..(Date.current + HORIZON_DAYS))
                        .includes(:recurring_transaction)
                        .order(:due_on)

    render plain: to_ical(occurrences), content_type: "text/calendar"
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
        X-WR-CALNAME:Sure Bills
        #{events.join}
        END:VCALENDAR
      ICAL
    end

    def escape_ical(text)
      text.to_s.gsub("\\", "\\\\\\\\").gsub(",", "\\,").gsub(";", "\\;").gsub("\n", " ")
    end
end
