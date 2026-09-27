# frozen_string_literal: true

# Public BIP84 test vectors, never a user's keys or account data.
module BitcoinWalletTestHelper
  ZPUB = "zpub6rFR7y4Q2AijBEqTUquhVz398htDFrtymD9xYYfG1m4wAcvPhXNfE3EfH1r1ADqtfSdVCToUG868RvUUkgDKf31mGDtKsAYz2oz2AGutZYs"
  RECEIVE = "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu"
  SECOND = "bc1qnjg0jd8228aq7egyzacy8cys3knf9xvrerkf9g"
  CHANGE = "bc1q8c6fshw2dlwun7ekn9qwf37cu2rn755upcp6el"

  class FakeProvider
    attr_accessor :summaries, :transactions, :statuses, :truncated
    attr_reader :reads

    def initialize
      @summaries = {}
      @transactions = {}
      @statuses = {}
      @truncated = false
      @reads = []
    end

    def tip_hash
      "a" * 64
    end

    def tip_height
      100
    end

    def get_address(address)
      @reads << address
      result = summaries.fetch(address) do
        { "chain_stats" => { "tx_count" => 0, "funded_txo_sum" => 0, "spent_txo_sum" => 0 },
          "mempool_stats" => { "tx_count" => 0, "funded_txo_sum" => 0, "spent_txo_sum" => 0 } }
      end
      result = Marshal.load(Marshal.dump(result))
      result["mempool_stats"]["tx_count"] = transactions.fetch(address, []).count { |tx| tx.dig("status", "confirmed") == false }
      result
    end

    def get_wallet_transactions(address, since: nil, include_history: true, include_mempool: true)
      transactions.fetch(address, []).select do |tx|
        tx.dig("status", "confirmed") ? include_history : include_mempool
      end
    end

    def get_transaction_status(txid)
      statuses[txid]
    end

    def fund(address, sats, used: true)
      summaries[address] = { "chain_stats" => { "tx_count" => used ? 1 : 0, "funded_txo_sum" => sats, "spent_txo_sum" => 0 },
        "mempool_stats" => { "tx_count" => 0, "funded_txo_sum" => 0, "spent_txo_sum" => 0 } }
    end
  end

  def build_bitcoin_wallet(account: accounts(:crypto), **attributes)
    security = Security.find_or_create_by!(ticker: "CRYPTO:BTC") { |row| row.name = "Bitcoin" }
    security.prices.find_or_create_by!(date: Date.current) { |row| row.price = 10_000; row.currency = "USD" }
    item = account.family.onchain_wallet_items.first || account.family.onchain_wallet_items.create!(name: "Wallets")
    BitcoinWalletAccount.create!(account: account, security: security, onchain_wallet_item: item, **attributes)
  end

  def manual_bitcoin_source(wallet, address = RECEIVE)
    wallet.bitcoin_wallet_sources.create!(kind: "address", receive_address: address)
  end

  def bitcoin_transaction(id: "b" * 64, inputs: [], outputs: [], confirmed: true, time: Time.current)
    { "txid" => id, "vin" => inputs.map { |address, sats| { "prevout" => { "scriptpubkey_address" => address, "value" => sats } } },
      "vout" => outputs.map { |address, sats| { "scriptpubkey_address" => address, "value" => sats } },
      "status" => { "confirmed" => confirmed, "block_height" => confirmed ? 100 : nil,
        "block_time" => confirmed ? time.to_i : nil } }
  end
end
