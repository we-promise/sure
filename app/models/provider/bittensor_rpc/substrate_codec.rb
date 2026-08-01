# frozen_string_literal: true

# Minimal Substrate helpers for keyless Bittensor balance reads:
# SS58 decode, Twox128, Blake2b-128, and AccountInfo free-balance decode.
# Kept dependency-free (no polkadot/substrate gems) to match Sure conventions.
class Provider::BittensorRpc::SubstrateCodec
  BASE58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
  SS58_PREFIX = "SS58PRE"

  # Bittensor / Substrate default network prefix (42) → addresses typically start with "5".
  BITTENSOR_PREFIX = 42

  class << self
    def ss58_account_id(address)
      raw = base58_decode(address.to_s)
      prefix, account, checksum =
        case raw.bytesize
        when 35
          [ raw.byteslice(0, 1), raw.byteslice(1, 32), raw.byteslice(33, 2) ]
        when 36
          [ raw.byteslice(0, 2), raw.byteslice(2, 32), raw.byteslice(34, 2) ]
        else
          return nil
        end

      return nil unless account&.bytesize == 32 && checksum&.bytesize == 2
      return nil unless blake2b("#{SS58_PREFIX}#{prefix}#{account}", 64).byteslice(0, 2) == checksum

      account
    rescue ArgumentError
      nil
    end

    def valid_ss58?(address, expected_prefix: BITTENSOR_PREFIX)
      raw = base58_decode(address.to_s)
      prefix_len = raw.bytesize == 36 ? 2 : (raw.bytesize == 35 ? 1 : nil)
      return false unless prefix_len

      prefix_bytes = raw.byteslice(0, prefix_len)
      prefix = prefix_len == 1 ? prefix_bytes.getbyte(0) : (prefix_bytes.getbyte(0) + (prefix_bytes.getbyte(1) << 8))
      return false unless prefix == expected_prefix

      !ss58_account_id(address).nil?
    rescue ArgumentError
      false
    end

    def system_account_storage_key(account_id32)
      twox128("System") + twox128("Account") + blake2_128_concat(account_id32)
    end

    def decode_account_free_rao(storage_hex)
      return 0 if storage_hex.nil? || storage_hex.empty?

      hex = storage_hex.to_s.delete_prefix("0x")
      data = [ hex ].pack("H*")
      return 0 if data.bytesize < 32

      # AccountInfo: nonce/consumers/providers/sufficients (4×u32), then AccountData.free (u128 LE)
      data.byteslice(16, 16).each_byte.with_index.sum { |byte, i| byte * (256**i) }
    end

    def twox128(string)
      [ xxhash64(string, 0), xxhash64(string, 1) ].pack("Q<*")
    end

    def blake2_128_concat(account_id32)
      blake2b(account_id32, 16) + account_id32
    end

    def blake2b(data, outlen)
      Blake2b.digest(data, outlen)
    end

    def base58_decode(str)
      raise ArgumentError, "blank" if str.nil? || str.empty?

      int = 0
      str.each_char do |char|
        idx = BASE58_ALPHABET.index(char)
        raise ArgumentError, "invalid base58" unless idx

        int = int * 58 + idx
      end

      bytes = []
      while int > 0
        bytes.unshift(int % 256)
        int /= 256
      end
      str.each_char.take_while { |c| c == "1" }.size.times { bytes.unshift(0) }
      bytes.pack("C*")
    end

    # XXHash64 (seeded), little-endian digest integer — Substrate Twox uses seed 0 then 1.
    def xxhash64(input, seed)
      data = input.to_s.b
      len = data.bytesize
      i = 0
      prime1 = 0x9E3779B185EBCA87
      prime2 = 0xC2B2AE3D27D4EB4F
      prime3 = 0x165667B19E3779F9
      prime4 = 0x85EBCA77C2B2AE63
      prime5 = 0x27D4EB2F165667C5
      mask = (1 << 64) - 1

      rotl = ->(x, r) { ((x << r) | (x >> (64 - r))) & mask }
      round = lambda do |acc, input_lane|
        acc = (acc + ((input_lane * prime2) & mask)) & mask
        acc = rotl.call(acc, 31)
        (acc * prime1) & mask
      end
      merge = lambda do |acc, val|
        val = round.call(0, val)
        acc ^= val
        (((acc * prime1) & mask) + prime4) & mask
      end

      if len >= 32
        v1 = (seed + prime1 + prime2) & mask
        v2 = (seed + prime2) & mask
        v3 = seed & mask
        v4 = (seed - prime1) & mask
        while i + 32 <= len
          v1 = round.call(v1, data.byteslice(i, 8).unpack1("Q<")); i += 8
          v2 = round.call(v2, data.byteslice(i, 8).unpack1("Q<")); i += 8
          v3 = round.call(v3, data.byteslice(i, 8).unpack1("Q<")); i += 8
          v4 = round.call(v4, data.byteslice(i, 8).unpack1("Q<")); i += 8
        end
        h = (rotl.call(v1, 1) + rotl.call(v2, 7) + rotl.call(v3, 12) + rotl.call(v4, 18)) & mask
        h = merge.call(h, v1)
        h = merge.call(h, v2)
        h = merge.call(h, v3)
        h = merge.call(h, v4)
      else
        h = (seed + prime5) & mask
      end

      h = (h + len) & mask
      while i + 8 <= len
        k = data.byteslice(i, 8).unpack1("Q<"); i += 8
        h ^= round.call(0, k)
        h = rotl.call(h, 27)
        h = (((h * prime1) & mask) + prime4) & mask
      end
      if i + 4 <= len
        k = data.byteslice(i, 4).unpack1("V"); i += 4
        h ^= (k * prime1) & mask
        h = rotl.call(h, 23)
        h = (((h * prime2) & mask) + prime3) & mask
      end
      while i < len
        h ^= (data.getbyte(i) * prime5) & mask
        h = rotl.call(h, 11)
        h = (h * prime1) & mask
        i += 1
      end

      h ^= h >> 33
      h = (h * prime2) & mask
      h ^= h >> 29
      h = (h * prime3) & mask
      h ^= h >> 32
      h
    end
  end

  # Compact Blake2b (RFC 7693) supporting variable output length (we need 16 and 64).
  class Blake2b
    IV = [
      0x6A09E667F3BCC908, 0xBB67AE8584CAA73B, 0x3C6EF372FE94F82B, 0xA54FF53A5F1D36F1,
      0x510E527FADE682D1, 0x9B05688C2B3E6C1F, 0x1F83D9ABFB41BD6B, 0x5BE0CD19137E2179
    ].freeze

    SIGMA = [
      [ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 ],
      [ 14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3 ],
      [ 11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4 ],
      [ 7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8 ],
      [ 9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13 ],
      [ 2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9 ],
      [ 12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11 ],
      [ 13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10 ],
      [ 6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5 ],
      [ 10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0 ],
      [ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 ],
      [ 14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3 ]
    ].freeze

    MASK = (1 << 64) - 1

    def self.digest(data, outlen)
      new(outlen).tap { |d| d.update(data.to_s.b) }.final
    end

    def initialize(outlen)
      raise ArgumentError, "outlen must be 1..64" unless outlen.between?(1, 64)

      @outlen = outlen
      @h = IV.dup
      @h[0] ^= 0x01010000 ^ outlen
      @t = [ 0, 0 ]
      @buf = "".b
      @finalized = false
    end

    def update(data)
      data = data.to_s.b
      while data.bytesize.positive?
        if @buf.bytesize == 128
          increment_counter(128)
          compress(false)
          @buf = "".b
        end
        take = [ 128 - @buf.bytesize, data.bytesize ].min
        @buf << data.byteslice(0, take)
        data = data.byteslice(take, data.bytesize - take) || "".b
      end
      self
    end

    def final
      raise "already finalized" if @finalized

      @finalized = true
      increment_counter(@buf.bytesize)
      @buf = @buf.ljust(128, "\0".b)
      compress(true)
      @h.pack("Q<*").byteslice(0, @outlen)
    end

    private
      def increment_counter(inc)
        @t[0] = (@t[0] + inc) & MASK
        @t[1] = (@t[1] + 1) & MASK if @t[0] < inc
      end

      def rotr64(x, n)
        ((x >> n) | (x << (64 - n))) & MASK
      end

      def compress(last)
        v = @h + IV
        v[12] ^= @t[0]
        v[13] ^= @t[1]
        v[14] ^= MASK if last

        m = @buf.unpack("Q<*")
        12.times do |round|
          s = SIGMA[round]
          g = lambda do |a, b, c, d, x, y|
            v[a] = (v[a] + v[b] + m[x]) & MASK
            v[d] = rotr64(v[d] ^ v[a], 32)
            v[c] = (v[c] + v[d]) & MASK
            v[b] = rotr64(v[b] ^ v[c], 24)
            v[a] = (v[a] + v[b] + m[y]) & MASK
            v[d] = rotr64(v[d] ^ v[a], 16)
            v[c] = (v[c] + v[d]) & MASK
            v[b] = rotr64(v[b] ^ v[c], 63)
          end
          g.call(0, 4, 8, 12, s[0], s[1])
          g.call(1, 5, 9, 13, s[2], s[3])
          g.call(2, 6, 10, 14, s[4], s[5])
          g.call(3, 7, 11, 15, s[6], s[7])
          g.call(0, 5, 10, 15, s[8], s[9])
          g.call(1, 6, 11, 12, s[10], s[11])
          g.call(2, 7, 8, 13, s[12], s[13])
          g.call(3, 4, 9, 14, s[14], s[15])
        end

        8.times { |i| @h[i] ^= v[i] ^ v[i + 8] }
      end
  end
end
