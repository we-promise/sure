# frozen_string_literal: true

# auto_login_time is the opt-in daily time ("HH:MM", family time zone) at
# which the Trade Republic login starts by itself; nil means off.
# auto_login_token identifies the current schedule, so jobs planned before
# the setting changed can tell they are stale and do nothing.
# auto_login_planned_for is the start already queued for that schedule, so a
# rerun of a day's first attempt does not queue the next day twice.
class AddAutoLoginToTradeRepublicItems < ActiveRecord::Migration[8.1]
  def change
    add_column :trade_republic_items, :auto_login_time, :string
    add_column :trade_republic_items, :auto_login_token, :string
    add_column :trade_republic_items, :auto_login_planned_for, :datetime
  end
end
