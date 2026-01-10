class MarkSuspiciousPricesProvisional < ActiveRecord::Migration[7.2]
  def up
    # Mark recent weekday prices as provisional if they deviate significantly
    # from surrounding prices (potential gap-fill errors from stale data)
    #
    # This fixes an issue where prices from old trade dates could propagate
    # to current dates during gap-fill when the market was closed.

    Security::Price
      .where(provisional: false)
      .where(date: 3.days.ago.to_date..Date.current)
      .where("EXTRACT(DOW FROM date) NOT IN (0, 6)") # Weekdays only
      .find_each do |price|
        # Get surrounding prices for comparison (previous 5 days, up to 3 prices)
        surrounding = Security::Price
          .where(security_id: price.security_id)
          .where(date: (price.date - 5.days)..(price.date - 1.day))
          .where(provisional: false)
          .order(date: :desc)
          .limit(3)
          .pluck(:price)

        next if surrounding.empty?

        avg_surrounding = surrounding.sum / surrounding.size
        next if avg_surrounding.zero?

        deviation = (price.price - avg_surrounding).abs / avg_surrounding

        # If price deviates more than 20% from recent average, mark provisional
        if deviation > 0.20
          price.update_column(:provisional, true)
          Rails.logger.info("Marked price #{price.id} as provisional (#{(deviation * 100).round(1)}% deviation from surrounding prices)")
        end
      end
  end

  def down
    # No-op: marking as provisional is safe and prices will auto-correct
    # on next sync when provider returns real data
  end
end
