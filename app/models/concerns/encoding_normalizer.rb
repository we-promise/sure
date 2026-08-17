module EncodingNormalizer
  # Fallback encodings tried in order when content is not valid UTF-8.
  # Windows-1252 covers the vast majority of European-language CSV files
  # exported from Excel/Windows.  Windows-1250 is tried next because it
  # covers the five byte values (0x81 etc.) that Windows-1252 leaves undefined.
  FALLBACK_ENCODINGS = %w[Windows-1252 Windows-1250].freeze

  # Converts *content* to a valid UTF-8 string.
  # If the content is already valid UTF-8 it is returned unchanged.
  # Otherwise each FALLBACK_ENCODING is attempted; if none succeeds, invalid
  # bytes are silently dropped.
  def self.normalize(content)
    return content if content.nil?

    binary = content.b  # Force ASCII-8BIT; never raises on invalid bytes

    utf8_attempt = binary.dup.force_encoding("UTF-8")
    return utf8_attempt if utf8_attempt.valid_encoding?

    FALLBACK_ENCODINGS.each do |encoding|
      begin
        return binary.encode("UTF-8", encoding)
      rescue Encoding::UndefinedConversionError
        next
      end
    end

    # Last resort: replace any remaining undefined bytes rather than raise
    binary.encode("UTF-8", "Windows-1252", invalid: :replace, undef: :replace, replace: "")
  end
end
