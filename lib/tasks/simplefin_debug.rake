# frozen_string_literal: true

require "json"
require "time"

namespace :sure do
  namespace :simplefin do
    desc "Print last N raw SimpleFin transactions for a given item/account name. Args: item_id, account_name, limit (default 15)"
    task :tx_debug, [ :item_id, :account_name, :limit ] => :environment do |_, args|
      unless args[:item_id].present? && args[:account_name].present?
        puts({ error: "usage", example: "bin/rails sure:simplefin:tx_debug[ITEM_ID,ACCOUNT_NAME,15]" }.to_json)
        exit 1
      end

      item = SimplefinItem.find(args[:item_id])
      limit = (args[:limit] || 15).to_i
      limit = 15 if limit <= 0

      sfa = item.simplefin_accounts.order(updated_at: :desc).find do |acc|
        acc.name.to_s.downcase.include?(args[:account_name].to_s.downcase)
      end

      unless sfa
        puts({ error: "not_found", message: "No SimplefinAccount matched", item_id: item.id, account_name: args[:account_name] }.to_json)
        exit 1
      end

      txs = Array(sfa.raw_transactions_payload)
      # Sort by best-known date: posted -> transacted_at -> as-is
      txs = txs.map { |t| t.with_indifferent_access }
      txs.sort_by! do |t|
        posted = t[:posted]
        trans = t[:transacted_at]
        ts = if posted.is_a?(Numeric)
          posted
        elsif trans.is_a?(Numeric)
          trans
        else
          0
        end
        -ts
      end

      sample = txs.first(limit)
      out = sample.map do |t|
        posted = t[:posted]
        trans  = t[:transacted_at]
        {
          id: t[:id],
          amount: t[:amount],
          description: t[:description],
          payee: t[:payee],
          memo: t[:memo],
          posted: posted,
          transacted_at: trans,
          pending_flag: t[:pending],
          inferred_pending: (trans.present? && posted.present? && posted.to_i > trans.to_i)
        }
      end

      puts({ item_id: item.id, sfa_id: sfa.id, sfa_name: sfa.name, count: txs.size, sample: out }.to_json)
    rescue => e
      puts({ error: e.class.name, message: e.message, backtrace: e.backtrace&.take(3) }.to_json)
      exit 1
    end

    desc "Print last N imported Entries for an account by name (linked to SimpleFin). Args: account_name, limit (default 15)"
    task :entries_debug, [ :account_name, :limit ] => :environment do |_, args|
      unless args[:account_name].present?
        puts({ error: "usage", example: "bin/rails sure:simplefin:entries_debug[ACCOUNT_NAME,15]" }.to_json)
        exit 1
      end

      acct = Account
        .where("LOWER(name) LIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(args[:account_name].to_s.downcase)}%")
        .order(updated_at: :desc)
        .first

      unless acct
        puts({ error: "not_found", message: "No Account matched", account_name: args[:account_name] }.to_json)
        exit 1
      end

      limit = (args[:limit] || 15).to_i
      limit = 15 if limit <= 0

      entries = acct.entries.includes(:entryable).where(entryable_type: "Transaction").order(date: :desc).limit(limit)
      out = entries.map do |e|
        {
          id: e.id,
          external_id: e.external_id,
          source: e.source,
          name: e.name,
          amount: e.amount,
          date: e.date,
          was_merged: (e.entryable.respond_to?(:was_merged) ? e.entryable.was_merged : nil)
        }
      end

      puts({ account_id: acct.id, account_name: acct.name, entries: out }.to_json)
    rescue => e
      puts({ error: e.class.name, message: e.message, backtrace: e.backtrace&.take(3) }.to_json)
      exit 1
    end
  end
end
