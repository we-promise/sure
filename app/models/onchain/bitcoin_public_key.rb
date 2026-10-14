# frozen_string_literal: true

module Onchain
  # An account-level mainnet key, interpreted explicitly as BIP84. An xpub's
  # version cannot tell us its script type, so the linking flow also verifies
  # an address the owner obtained independently from their hardware wallet.
  class BitcoinPublicKey
    class InvalidKey < ArgumentError; end

    VERSIONS = %w[0488b21e 04b24746].freeze # mainnet xpub, zpub
    BASE58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    CURVE = OpenSSL::PKey::EC::Group.new("secp256k1")

    # Parse a mainnet account-level xpub/zpub and reject private keys, wrong
    # depths and unsupported encodings before any address derivation occurs.
    def initialize(value)
      text = value.to_s.strip
      raise InvalidKey, "Use a mainnet account xpub or zpub" unless text.length <= 112 && text.start_with?("xpub", "zpub")

      # version(4) depth(1) parent fingerprint(4) child number(4) chain code(32) key(33)
      payload = self.class.base58check_decode(text)
      raise InvalidKey, "Invalid extended public key" unless payload&.bytesize == 78 && VERSIONS.include?(payload[0, 4].unpack1("H*"))
      raise InvalidKey, "Use an account-level extended public key" unless payload.getbyte(4) == 3

      @chain_code = payload[13, 32]
      @pub = payload[45, 33]
      OpenSSL::PKey::EC::Point.new(CURVE, @pub) # rejects private keys and off-curve points
    rescue StandardError => error
      raise InvalidKey, "Invalid extended public key" unless error.is_a?(InvalidKey)
      raise
    end

    # Derive a Native SegWit address on receive (0) or change (1), allowing only
    # non-hardened child indices obtainable from an account public key.
    def address(branch, index)
      raise InvalidKey, "Invalid derivation branch" unless [ 0, 1 ].include?(branch)
      raise InvalidKey, "Invalid address index" unless index.between?(0, 0x7fffffff)

      @branches ||= {}
      child, = derive(*(@branches[branch] ||= derive(@pub, @chain_code, branch)), index)
      segwit = Bech32::SegwitAddr.new
      segwit.ver = 0
      segwit.prog = OpenSSL::Digest.digest("RIPEMD160", OpenSSL::Digest.digest("SHA256", child)).bytes
      segwit.addr
    end

    # Identify public key material independently of its xpub/zpub version bytes,
    # so equivalent encodings cannot create duplicate sources. The key is hashed
    # as hex and the chain code as bytes, as stored fingerprints were computed.
    def fingerprint
      Digest::SHA256.hexdigest(@pub.unpack1("H*") + @chain_code)
    end

    # Validate the checksum and a standard mainnet output (P2PKH, P2SH, P2WPKH,
    # P2WSH, P2TR); malformed addresses and other networks return false.
    def self.valid_address?(value)
      text = value.to_s
      return false unless text.length.between?(26, 90)

      if text.match?(/\Abc1/i)
        segwit = Bech32::SegwitAddr.new(text)
        segwit.hrp == "bc" && (segwit.ver.zero? ? [ 20, 32 ].include?(segwit.prog.size) : segwit.ver == 1 && segwit.prog.size == 32)
      else
        payload = base58check_decode(text)
        payload&.bytesize == 21 && [ 0x00, 0x05 ].include?(payload.getbyte(0))
      end
    rescue StandardError
      false
    end

    # Trim input and normalize uniformly cased Bech32 addresses. Keep mixed case
    # unchanged so checksum validation rejects it rather than silently repairing it.
    def self.canonical_address(value)
      text = value.to_s.strip
      return text if text.match?(/\Abc1/i) && text != text.downcase && text != text.upcase

      text.match?(/\Abc1/i) ? text.downcase : text
    end

    # Decode Base58Check, returning nil when the checksum does not match.
    def self.base58check_decode(text)
      number = text.each_char.reduce(0) { |sum, char| sum * 58 + (BASE58.index(char) || raise(ArgumentError, "Invalid Base58")) }
      hex = number.zero? ? "" : number.to_s(16)
      bytes = ("\x00" * text[/\A1*/].size + [ hex.rjust(hex.size + hex.size % 2, "0") ].pack("H*")).b
      payload = bytes[0...-4]
      payload if bytes.bytesize > 4 && bytes[-4..] == OpenSSL::Digest.digest("SHA256", OpenSSL::Digest.digest("SHA256", payload))[0, 4]
    end

    private
      # BIP32 public child derivation (CKDpub) for a non-hardened index.
      def derive(pub, chain_code, index)
        digest = OpenSSL::HMAC.digest("SHA512", chain_code, pub + [ index ].pack("N"))
        tweak = OpenSSL::BN.new(digest[0, 32], 2)
        raise InvalidKey, "Invalid derived key" if tweak >= CURVE.order

        point = CURVE.generator.mul(tweak).add(OpenSSL::PKey::EC::Point.new(CURVE, pub))
        raise InvalidKey, "Invalid derived key" if point.infinity?

        [ point.to_octet_string(:compressed), digest[32, 32] ]
      end
  end
end
