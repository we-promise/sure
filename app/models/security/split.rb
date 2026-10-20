# A change in a security's share count that no trade made: a 2-for-1 split
# turns 10 shares into 20 on its ex-date, and a 1-for-10 reverse split turns
# 100 into 10. The money invested does not change, so cost per share moves by
# the inverse of the ratio.
#
# The holding calculators apply it at the open of the ex-date, before that
# day's trades (#249).
class Security::Split < ApplicationRecord
  # Who said the split happened. A user's own entry outranks a provider's, so a
  # sync never overwrites what someone recorded by hand (#3781). Each provider
  # that writes splits adds itself here.
  SOURCES = %w[manual snaptrade].freeze

  belongs_to :security

  validates :ex_date, :source, presence: true
  validates :source, inclusion: { in: SOURCES }, allow_blank: true
  validates :numerator, :denominator, numericality: { only_integer: true, greater_than: 0 }
  validates :ex_date, uniqueness: { scope: :security_id }
  validate :changes_the_share_count

  # New shares per old, exact.
  def ratio
    Rational(numerator, denominator)
  end

  def manual?
    source == "manual"
  end

  class << self
    # The one way a split row is written. Keyed on the security and ex-date,
    # under the security's row lock so two writers cannot race to the unique
    # index. A manual write replaces whatever is there; a provider's replaces
    # another provider's, but never a manual row: that row is kept, and a
    # provider that disagrees with it is recorded for support. Returns the row
    # that stands.
    def record!(security:, ex_date:, numerator:, denominator:, source:)
      security.with_lock do
        split = security.splits.find_or_initialize_by(ex_date: ex_date)

        if split.persisted? && split.manual? && source.to_s != "manual"
          report_overruled(split, Rational(numerator, denominator), source)
          next split
        end

        split.assign_attributes(numerator: numerator, denominator: denominator, source: source)
        next split unless split.changed?

        split.save!
        split.send(:rematerialize_holders)
        split
      end
    end

    # Re-points a merged duplicate's splits at the security that replaces it.
    # On an ex-date both have, the manual row stays over a provider's, and
    # between equals the canonical security's stays. The other is deleted.
    # Returns how many were moved and how many dropped.
    def move!(from:, to:)
      counts = { moved: 0, dropped: 0 }

      where(security_id: Array(from).map(&:id)).find_each do |split|
        existing = to.splits.find_by(ex_date: split.ex_date)

        if existing.nil?
          split.update!(security: to)
          counts[:moved] += 1
        elsif split.manual? && !existing.manual?
          existing.destroy!
          split.update!(security: to)
          counts[:moved] += 1
        else
          split.destroy!
          counts[:dropped] += 1
        end
      end

      counts
    end

    private
      def report_overruled(split, provider_ratio, provider)
        return if provider_ratio == split.ratio

        DebugLogEntry.capture(
          category: "security_split",
          level: "warn",
          message: "Provider split differs from a manually recorded split; the manual one is kept",
          source: name,
          provider_key: provider.to_s,
          metadata: {
            security_id: split.security_id,
            ticker: split.security.ticker,
            ex_date: split.ex_date.iso8601,
            provider_ratio: "#{provider_ratio.numerator}:#{provider_ratio.denominator}",
            manual_ratio: "#{split.ratio.numerator}:#{split.ratio.denominator}"
          }
        )
      end
  end

  # Changes an existing row in place, a moved ex-date included. Unlike
  # .record!, this edits a row the caller already holds, so precedence is
  # the caller's decision.
  def revise!(ex_date:, numerator:, denominator:, source:)
    update!(ex_date: ex_date, numerator: numerator, denominator: denominator, source: source)
    rematerialize_holders if saved_changes?
    self
  end

  def remove!
    destroy!
    rematerialize_holders
  end

  # The scale of the `qty` columns on `holdings` and `trades`. A quantity this
  # code hands around has to be one the database can hold: anything finer is a
  # number no position can actually be in.
  QTY_SCALE = 18

  # A share count after a split of `ratio`, and before it. Multiplying a
  # BigDecimal by a Rational rounds at 32 digits, so 3 shares through a
  # 1-for-3 split came out 0.999...; multiplying by the numerator and then
  # dividing by the denominator is exact whenever the answer is.
  #
  # When the answer doesn't terminate -- 10 shares through a 1-for-3 split is
  # 3.333... -- the result is rounded to the stored scale. Carrying the extra
  # digits instead left a position that had been sold in full holding about
  # 3e-31 of a share: the seller can only sell what the column can hold, so the
  # subtraction missed exact zero, the cost-basis tracker never reset, and an
  # inbound transfer's "cost unknown" mark survived a full liquidation.
  #
  # The cost of rounding here is that scaling and unscaling back can land one
  # unit in the last place away from where it started. That is the floor the
  # column imposes anyway.
  def self.scale(qty, ratio)
    (qty.to_d * ratio.numerator / ratio.denominator).round(QTY_SCALE)
  end

  def self.unscale(qty, ratio)
    (qty.to_d * ratio.denominator / ratio.numerator).round(QTY_SCALE)
  end

  private
    # Every account with a holding or a trade in the security, in any family:
    # a split changes all of their share counts. One job each, enqueued after
    # the write commits (ApplicationJob.enqueue_after_transaction_commit).
    def rematerialize_holders
      trade_account_ids = Entry.where(entryable_type: "Trade", entryable_id: Trade.where(security_id: security_id).select(:id)).select(:account_id)
      holding_account_ids = Holding.where(security_id: security_id).select(:account_id)

      Account.where(id: trade_account_ids).or(Account.where(id: holding_account_ids)).find_each do |account|
        SecuritySplitRematerializeJob.perform_later(account, security)
      end
    end

    # A 1:1 "split" changes nothing, and the DB refuses it too. Reuses Rails'
    # own `other_than` message, so no new string is needed.
    def changes_the_share_count
      errors.add(:denominator, :other_than, count: numerator) if numerator.present? && numerator == denominator
    end
end
