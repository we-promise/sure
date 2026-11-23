# Verifies DKIM signatures (RFC 6376) on a raw RFC 5322 message.
#
# Bank alert emails reach Sure through a forwarding chain (Gmail filter ->
# inbound address -> webhook), so the envelope and SPF say nothing about who
# wrote the message. The bank's DKIM signature survives forwarding (headers and
# body are not rewritten), and it is the only thing that proves an alert really
# came from the bank. Without it anyone who learns the inbound address could
# email in fake transactions.
#
# Supports rsa-sha256 and ed25519-sha256 with simple/relaxed canonicalization.
# Signatures using the l= (body length) tag are rejected: they let content be
# appended after the signed part of the body.
class EmailAlert::DkimVerifier
  Result = Data.define(:domain, :selector, :status, :reason) do
    def pass? = status == :pass
  end

  class KeyResolver
    CACHE_TTL = 1.hour

    def call(selector, domain)
      name = "#{selector}._domainkey.#{domain}"
      Rails.cache.fetch("email_alert/dkim_key/#{name}", expires_in: CACHE_TTL, skip_nil: true) do
        Resolv::DNS.open do |dns|
          dns.timeouts = 5
          records = dns.getresources(name, Resolv::DNS::Resource::IN::TXT)
          records.map { |r| r.strings.join }.find { |txt| txt.include?("p=") }
        end
      end
    rescue Resolv::ResolvError, SocketError, Timeout::Error
      nil
    end
  end

  def initialize(raw_message, key_resolver: KeyResolver.new)
    @raw = normalize_line_endings(raw_message.to_s.b)
    @key_resolver = key_resolver
  end

  # Results for every DKIM-Signature header on the message, in header order.
  def results
    @results ||= signature_headers.map { |header| verify_signature(header) }
  end

  # The domains with at least one passing signature.
  def passing_domains
    results.select(&:pass?).map(&:domain).uniq
  end

  # True when a passing signature's d= equals +domain+ or is a parent of it
  # (d=gtbank.com covers mail from alerts.gtbank.com, never the reverse).
  def passes_for?(domain)
    domain = domain.to_s.downcase
    passing_domains.any? { |d| domain == d || domain.end_with?(".#{d}") }
  end

  private

    attr_reader :raw, :key_resolver

    def normalize_line_endings(str)
      str.gsub(/\r?\n/, "\r\n")
    end

    def header_section
      @header_section ||= split_message.first
    end

    def body
      @body ||= split_message.last
    end

    def split_message
      @split_message ||= begin
        idx = raw.index("\r\n\r\n")
        idx ? [ raw[0, idx + 2], raw[(idx + 4)..] ] : [ raw, "".b ]
      end
    end

    # Each header as its full raw text (name, colon, value, folded lines), CRLF-terminated.
    def headers
      @headers ||= header_section.split(/\r\n(?![ \t])/).reject(&:empty?).map { |h| "#{h}\r\n" }
    end

    def header_name(header)
      header[/\A[^:]+/].to_s.strip.downcase
    end

    def signature_headers
      headers.select { |h| header_name(h) == "dkim-signature" }
    end

    def verify_signature(signature_header)
      tags = parse_tags(signature_header.split(":", 2).last)
      domain = tags["d"].to_s.downcase
      selector = tags["s"].to_s
      fail_with = ->(reason, status = :fail) { Result.new(domain:, selector:, status:, reason:) }

      return fail_with.("unsupported version", :invalid) unless tags["v"] == "1"
      return fail_with.("missing required tags", :invalid) if [ "a", "b", "bh", "d", "h", "s" ].any? { |t| tags[t].blank? }
      return fail_with.("l= tag not accepted", :invalid) if tags.key?("l")

      algorithm = tags["a"].downcase
      return fail_with.("unsupported algorithm #{algorithm}", :invalid) unless [ "rsa-sha256", "ed25519-sha256" ].include?(algorithm)

      signed_header_names = tags["h"].split(":").map { |n| n.strip.downcase }
      return fail_with.("From header not signed", :invalid) unless signed_header_names.include?("from")

      header_canon, body_canon = tags.fetch("c", "simple/simple").downcase.split("/", 2)
      body_canon ||= "simple"
      return fail_with.("unsupported canonicalization", :invalid) unless [ header_canon, body_canon ].all? { |c| [ "simple", "relaxed" ].include?(c) }

      body_hash = Base64.strict_encode64(OpenSSL::Digest::SHA256.digest(canonicalize_body(body, body_canon)))
      return fail_with.("body hash mismatch") unless secure_compare(body_hash, tags["bh"].gsub(/\s/, ""))

      key_record = key_resolver.call(selector, domain)
      return fail_with.("no DNS key", :temperror) if key_record.blank?

      public_key = load_public_key(key_record, algorithm)
      return fail_with.("unusable DNS key", :permerror) unless public_key

      signed_data = signed_headers(signed_header_names, header_canon) +
                    canonicalize_header(strip_signature_value(signature_header), header_canon).delete_suffix("\r\n")
      signature = Base64.decode64(tags["b"].gsub(/\s/, ""))

      valid = if algorithm == "rsa-sha256"
        public_key.verify("SHA256", signature, signed_data)
      else
        public_key.verify(nil, signature, OpenSSL::Digest::SHA256.digest(signed_data))
      end

      valid ? Result.new(domain:, selector:, status: :pass, reason: nil) : fail_with.("signature mismatch")
    rescue OpenSSL::PKey::PKeyError, ArgumentError => e
      Result.new(domain:, selector:, status: :fail, reason: e.message)
    end

    def parse_tags(value)
      value.to_s.gsub(/\r\n[ \t]/, " ").split(";").each_with_object({}) do |pair, tags|
        key, val = pair.split("=", 2)
        next if key.blank? || val.nil?
        tags[key.strip] = val.strip
      end
    end

    # Per RFC 6376 3.5: for a header name listed n times, use the last n
    # instances, bottom-up. Names listed but absent contribute nothing.
    def signed_headers(names, canon)
      remaining = Hash.new { |h, k| h[k] = headers.select { |hdr| header_name(hdr) == k } }
      names.filter_map do |name|
        instance = remaining[name].pop
        instance && canonicalize_header(instance, canon)
      end.join
    end

    def strip_signature_value(header)
      # Empty the b= tag's value (but not bh=), keeping everything else byte-for-byte.
      header.sub(/(\A|;)([ \t\r\n]*b[ \t\r\n]*=)[^;]*/) { "#{$1}#{$2}" }
    end

    def canonicalize_header(header, canon)
      return header if canon == "simple"

      name, value = header.split(":", 2)
      value = value.to_s.gsub(/\r\n(?=[ \t])/, "").gsub(/[ \t]+/, " ").strip
      "#{name.strip.downcase}:#{value}\r\n"
    end

    def canonicalize_body(body, canon)
      if canon == "relaxed"
        lines = body.split("\r\n", -1).map { |line| line.gsub(/[ \t]+/, " ").sub(/ \z/, "") }
        text = lines.join("\r\n").sub(/(\r\n)*\z/, "")
        text.empty? ? "" : "#{text}\r\n"
      else
        text = body.sub(/(\r\n)*\z/, "")
        "#{text}\r\n"
      end
    end

    def load_public_key(record, algorithm)
      tags = parse_tags(record)
      key_data = tags["p"].to_s.gsub(/\s/, "")
      return nil if key_data.empty? # revoked key

      der = Base64.decode64(key_data)
      key_type = tags.fetch("k", "rsa").downcase

      if algorithm == "ed25519-sha256"
        return nil unless key_type == "ed25519"
        OpenSSL::PKey.new_raw_public_key("ED25519", der)
      else
        return nil unless key_type == "rsa"
        OpenSSL::PKey::RSA.new(der)
      end
    rescue OpenSSL::PKey::PKeyError, ArgumentError
      nil
    end

    def secure_compare(a, b)
      ActiveSupport::SecurityUtils.secure_compare(a, b)
    end
end
