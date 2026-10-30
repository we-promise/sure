# frozen_string_literal: true

json.id lot.id
json.opening lot.opening?
json.acquired_on lot.acquired_on&.iso8601
json.qty lot.qty
json.unit_cost lot.unit_cost && Money.new(lot.unit_cost, lot.currency).format
json.manual_cost lot.manual_cost?
json.trade_id lot.trade_id
