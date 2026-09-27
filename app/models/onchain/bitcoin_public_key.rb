# frozen_string_literal: true

module Onchain
  # An account-level mainnet key, interpreted explicitly as BIP84. An xpub's
  # version cannot tell us its script type, so the linking flow also verifies
  # an address the owner obtained independently from their hardware wallet.
  class BitcoinPublicKey
    class InvalidKey < ArgumentError; end

    def initialize(value)
      text = value.to_s.strip
      raise InvalidKey, "Use a mainnet account xpub or zpub" unless text.length <= 112 && text.start_with?("xpub", "zpub")

      @key = Bitcoin::ExtPubkey.from_base58(text)
      raise InvalidKey, "Use an account-level extended public key" unless @key.depth == 3
    rescue StandardError => error
      raise InvalidKey, "Invalid extended public key" unless error.is_a?(InvalidKey)
      raise
    end

    def address(branch, index)
      raise InvalidKey, "Invalid derivation branch" unless [ 0, 1 ].include?(branch)
      raise InvalidKey, "Invalid address index" unless index.between?(0, 0x7fffffff)

      @branches ||= {}
      child = (@branches[branch] ||= @key.derive(branch)).derive(index)
      Bitcoin::Key.new(pubkey: child.pub).to_p2wpkh
    end

    def fingerprint
      # xpub and zpub encodings of the same key are the same source.
      Digest::SHA256.hexdigest(@key.pub + @key.chain_code)
    end

    def self.valid_address?(value)
      return false unless value.to_s.length.between?(26, 90)

      script = Bitcoin::Script.parse_from_addr(value.to_s)
      script.p2pkh? || script.p2sh? || script.p2wpkh? || script.p2wsh? || script.p2tr?
    rescue StandardError
      false
    end

    def self.canonical_address(value)
      text = value.to_s.strip
      return text if text.match?(/\Abc1/i) && text != text.downcase && text != text.upcase

      text.match?(/\Abc1/i) ? text.downcase : text
    end
  end
end
