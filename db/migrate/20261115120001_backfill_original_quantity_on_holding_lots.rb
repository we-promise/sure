# Backfills `original_quantity` and `original_quantity_as_of` on existing opening
# holding lots (`source_entry_id IS NULL`) in small, plain-SQL batches.
#
# Runs with `disable_ddl_transaction!` so each batch commits on its own without
# holding long-running locks on `holding_lots`, and references no application
# models so future model changes cannot break historical migrations.
class BackfillOriginalQuantityOnHoldingLots < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  BATCH_SIZE = 500
  QTY_SCALE = 18

  def up
    total_updated = 0
    last_id = nil

    loop do
      rows = fetch_batch(last_id)
      break if rows.empty?

      last_id = rows.last["id"]
      updates = compute_batch_updates(rows)
      total_updated += apply_batch_updates(updates)
    end

    incomplete = connection.select_value(<<~SQL.squish).to_i
      SELECT COUNT(*) FROM holding_lots
      WHERE source_entry_id IS NULL AND original_quantity IS NULL
    SQL
    say "Backfilled #{total_updated} opening holding lots (#{incomplete} incomplete remaining)"
  end

  def down
    loop do
      updated = connection.exec_update(<<~SQL.squish)
        UPDATE holding_lots
        SET original_quantity = NULL, original_quantity_as_of = NULL
        WHERE id IN (
          SELECT id FROM holding_lots
          WHERE source_entry_id IS NULL AND original_quantity IS NOT NULL
          LIMIT #{BATCH_SIZE}
        )
      SQL
      break if updated.zero?
    end
  end

  private

    def fetch_batch(last_id)
      after_clause = last_id ? "AND hl.id > #{connection.quote(last_id)}" : ""
      connection.select_all(<<~SQL.squish).to_a
        SELECT hl.id, hl.account_id, hl.security_id, hl.qty, hl.clamped, hl.updated_at
        FROM holding_lots hl
        WHERE hl.source_entry_id IS NULL
          AND hl.original_quantity IS NULL
          #{after_clause}
        ORDER BY hl.id
        LIMIT #{BATCH_SIZE}
      SQL
    end

    def compute_batch_updates(rows)
      account_ids = rows.map { |row| row["account_id"] }.uniq
      security_ids = rows.map { |row| row["security_id"] }.uniq
      today = Date.current

      context = {
        today: today,
        linked_accounts: load_linked_accounts(account_ids),
        min_entry_dates: load_min_entry_dates(account_ids),
        provider_holdings_by_key: load_provider_holdings(account_ids, security_ids),
        provider_dates_by_account: load_provider_dates_by_account(account_ids),
        splits_by_security: load_splits(security_ids, today),
        trades_by_key: load_trades(account_ids, security_ids, today)
      }

      sale_entry_ids = context[:trades_by_key].values.flatten.select { |t| t[:qty].negative? }.map { |t| t[:id] }
      context[:disposals_by_sale] = load_disposals(sale_entry_ids)

      rows.map do |row|
        basis_date = [ parse_date(row["updated_at"]), today ].compact.min || today
        orig_qty = if row["clamped"] == true || row["clamped"] == "t"
          BigDecimal("0")
        else
          reconstruct_original_quantity(row, basis_date, context)
        end
        [ row["id"], orig_qty, basis_date ]
      end
    end

    def apply_batch_updates(updates)
      return 0 if updates.empty?

      values_sql = updates.map do |id, orig_qty, basis_date|
        qty_str = orig_qty.to_d.round(QTY_SCALE).to_s("F")
        "(#{connection.quote(id)}::uuid, #{connection.quote(qty_str)}::numeric(34,18), #{connection.quote(basis_date.iso8601)}::date)"
      end.join(", ")

      connection.transaction do
        connection.exec_update(<<~SQL.squish)
          UPDATE holding_lots AS hl
          SET original_quantity = v.orig_qty,
              original_quantity_as_of = v.basis_date
          FROM (VALUES #{values_sql}) AS v(id, orig_qty, basis_date)
          WHERE hl.id = v.id
            AND hl.original_quantity IS NULL
        SQL
      end
    end

    def reconstruct_original_quantity(row, basis_date, context)
      account_id = row["account_id"]
      security_id = row["security_id"]
      hl_qty = [ row["qty"].to_d, BigDecimal("0") ].max
      key = [ account_id, security_id ]

      trades = context[:trades_by_key].fetch(key, []).select { |t| t[:date] <= basis_date }
      all_splits = context[:splits_by_security].fetch(security_id, []).select { |s| s[:ex_date] <= basis_date }

      min_entry_date = context[:min_entry_dates][account_id]
      account_start_date = (min_entry_date && min_entry_date <= basis_date ? min_entry_date : basis_date) - 1
      replay_splits = all_splits.select { |s| s[:ex_date] >= account_start_date }

      events = trades.each_with_index.map { |t, idx| [ t[:date], 1, idx, :trade, t ] } +
               replay_splits.each_with_index.map { |s, idx| [ s[:ex_date], 0, idx, :split, s ] }
      events.sort_by! { |date, kind, idx, _, _| [ date, kind, idx ] }

      baseline = resolve_linked_baseline(account_id, security_id, basis_date, trades, all_splits, events, context)
      if baseline
        reconstruct_capped(hl_qty, baseline, events, context[:disposals_by_sale])
      else
        reconstruct_from_disposals(hl_qty, events, context[:disposals_by_sale])
      end
    end

    def resolve_linked_baseline(account_id, security_id, basis_date, trades, all_splits, events, context)
      provider_dates = context[:provider_dates_by_account].fetch(account_id, [])
      snapshot_date = provider_dates.select { |d| d <= basis_date }.max
      linked = context[:linked_accounts].include?(account_id)
      return nil unless snapshot_date || linked

      if snapshot_date
        provider_holding = context[:provider_holdings_by_key].fetch([ account_id, security_id ], [])
          .select { |h| h[:date] == snapshot_date }
          .max_by { |h| h[:id] }
        snapshot_qty = provider_holding ? provider_holding[:qty] : BigDecimal("0")
        effective_date = provider_holding ? provider_holding[:date] : snapshot_date
      else
        # Linked account with no provider_holding row yet: mirror PortfolioSnapshot fallback.
        fallback = latest_any_holding(account_id, security_id, basis_date)
        return nil unless fallback

        snapshot_qty = fallback[:qty]
        effective_date = fallback[:date]
      end

      pos = snapshot_qty
      if effective_date && effective_date < basis_date
        all_splits.each do |split|
          next unless split[:ex_date] > effective_date && split[:ex_date] <= basis_date

          pos = scale_qty(pos, split[:numerator], split[:denominator])
        end
      end

      return [ pos, BigDecimal("0") ].max if trades.empty?

      events.reverse_each do |_, _, _, kind, payload|
        if kind == :split
          pos = unscale_qty(pos, payload[:numerator], payload[:denominator])
        else
          pos -= payload[:qty]
        end
      end

      [ pos, BigDecimal("0") ].max
    end

    def reconstruct_capped(hl_qty, baseline, events, disposals_by_sale)
      remaining = baseline
      opening_consumed = BigDecimal("0")

      events.each do |_, _, _, kind, payload|
        if kind == :split
          remaining = scale_qty(remaining, payload[:numerator], payload[:denominator])
          opening_consumed = scale_qty(opening_consumed, payload[:numerator], payload[:denominator])
        elsif payload[:qty].negative?
          disposals = disposals_by_sale.fetch(payload[:id], [])
          nil_qty = disposals.sum(BigDecimal("0")) { |d| d[:lot_source_entry_id].nil? ? d[:qty] : BigDecimal("0") }
          opening_share = [ nil_qty, remaining ].min
          opening_consumed += opening_share
          remaining -= opening_share
        end
      end

      [ hl_qty + opening_consumed, remaining + opening_consumed, hl_qty, BigDecimal("0") ].max
    end

    def reconstruct_from_disposals(hl_qty, events, disposals_by_sale)
      opening_consumed = BigDecimal("0")
      opening_depleted = false

      events.each do |_, _, _, kind, payload|
        if kind == :split
          opening_consumed = scale_qty(opening_consumed, payload[:numerator], payload[:denominator])
        elsif payload[:qty].negative?
          next if opening_depleted

          disposals = disposals_by_sale.fetch(payload[:id], [])
          named_lot_id = payload[:lot_source_entry_id]
          nil_qty = disposals.sum(BigDecimal("0")) { |d| d[:lot_source_entry_id].nil? ? d[:qty] : BigDecimal("0") }
          unnamed_buy_disposal = disposals.any? { |d| d[:lot_source_entry_id] && d[:lot_source_entry_id] != named_lot_id }

          opening_consumed += nil_qty if nil_qty.positive?
          opening_depleted = true if unnamed_buy_disposal
        end
      end

      [ hl_qty + opening_consumed, hl_qty, BigDecimal("0") ].max
    end

    def load_linked_accounts(account_ids)
      return Set.new if account_ids.empty?

      connection.select_values(<<~SQL.squish).to_set
        SELECT DISTINCT account_id FROM account_providers
        WHERE account_id IN (#{quoted_list(account_ids)})
      SQL
    end

    def load_min_entry_dates(account_ids)
      return {} if account_ids.empty?

      connection.select_rows(<<~SQL.squish).to_h { |account_id, min_date| [ account_id, parse_date(min_date) ] }
        SELECT account_id, MIN(date) FROM entries
        WHERE account_id IN (#{quoted_list(account_ids)})
        GROUP BY account_id
      SQL
    end

    def load_provider_dates_by_account(account_ids)
      return {} if account_ids.empty?

      grouped = Hash.new { |h, k| h[k] = [] }
      connection.select_rows(<<~SQL.squish).each { |account_id, date| grouped[account_id] << parse_date(date) }
        SELECT DISTINCT account_id, date FROM holdings
        WHERE account_id IN (#{quoted_list(account_ids)})
          AND account_provider_id IS NOT NULL
      SQL
      grouped
    end

    def load_provider_holdings(account_ids, security_ids)
      return {} if account_ids.empty? || security_ids.empty?

      grouped = Hash.new { |h, k| h[k] = [] }
      connection.select_all(<<~SQL.squish).each do |row|
        SELECT id, account_id, security_id, date, qty FROM holdings
        WHERE account_id IN (#{quoted_list(account_ids)})
          AND security_id IN (#{quoted_list(security_ids)})
          AND account_provider_id IS NOT NULL
      SQL
        grouped[[ row["account_id"], row["security_id"] ]] << {
          id: row["id"], date: parse_date(row["date"]), qty: row["qty"].to_d
        }
      end
      grouped
    end

    def latest_any_holding(account_id, security_id, basis_date)
      row = connection.select_one(<<~SQL.squish)
        SELECT date, qty FROM holdings
        WHERE account_id = #{connection.quote(account_id)}
          AND security_id = #{connection.quote(security_id)}
          AND date <= #{connection.quote(basis_date.iso8601)}
        ORDER BY date DESC, id DESC
        LIMIT 1
      SQL
      row && { date: parse_date(row["date"]), qty: row["qty"].to_d }
    end

    def load_splits(security_ids, max_date)
      return {} if security_ids.empty?

      grouped = Hash.new { |h, k| h[k] = [] }
      connection.select_all(<<~SQL.squish).each do |row|
        SELECT security_id, ex_date, numerator, denominator FROM security_splits
        WHERE security_id IN (#{quoted_list(security_ids)})
          AND ex_date <= #{connection.quote(max_date.iso8601)}
        ORDER BY ex_date ASC, id ASC
      SQL
        grouped[row["security_id"]] << {
          ex_date: parse_date(row["ex_date"]),
          numerator: row["numerator"].to_i,
          denominator: row["denominator"].to_i
        }
      end
      grouped
    end

    def load_trades(account_ids, security_ids, max_date)
      return {} if account_ids.empty? || security_ids.empty?

      grouped = Hash.new { |h, k| h[k] = [] }
      connection.select_all(<<~SQL.squish).each do |row|
        SELECT e.id, e.account_id, t.security_id, e.date, t.qty, t.lot_source_entry_id
        FROM entries e
        JOIN trades t ON t.id = e.entryable_id AND e.entryable_type = 'Trade'
        WHERE e.account_id IN (#{quoted_list(account_ids)})
          AND t.security_id IN (#{quoted_list(security_ids)})
          AND e.date <= #{connection.quote(max_date.iso8601)}
        ORDER BY e.date ASC, e.created_at ASC, CASE WHEN t.qty < 0 THEN 1 ELSE 0 END ASC, e.id ASC
      SQL
        grouped[[ row["account_id"], row["security_id"] ]] << {
          id: row["id"],
          date: parse_date(row["date"]),
          qty: row["qty"].to_d,
          lot_source_entry_id: row["lot_source_entry_id"]
        }
      end
      grouped
    end

    def load_disposals(sale_entry_ids)
      return {} if sale_entry_ids.empty?

      grouped = Hash.new { |h, k| h[k] = [] }
      connection.select_all(<<~SQL.squish).each do |row|
        SELECT sale_entry_id, lot_source_entry_id, qty
        FROM holding_lot_disposals
        WHERE sale_entry_id IN (#{quoted_list(sale_entry_ids)})
      SQL
        grouped[row["sale_entry_id"]] << {
          lot_source_entry_id: row["lot_source_entry_id"],
          qty: row["qty"].to_d
        }
      end
      grouped
    end

    def scale_qty(qty, numerator, denominator)
      (qty.to_d * numerator / denominator).round(QTY_SCALE)
    end

    def unscale_qty(qty, numerator, denominator)
      (qty.to_d * denominator / numerator).round(QTY_SCALE)
    end

    def parse_date(value)
      return nil if value.nil?
      return value if value.is_a?(Date) && !value.is_a?(DateTime)

      value.to_date
    end

    def quoted_list(values)
      values.map { |value| connection.quote(value) }.join(", ")
    end
end
