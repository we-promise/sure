# HTTP for Account::LogoFetcher: follows https redirects, treats network
# failures as "nothing found", and turns image responses into sized icons.
class Account::LogoFetcher::Client
  # Favicon services answer unknown domains with a 16px (or 1px) placeholder.
  MIN_SIZE = 17
  MAX_REDIRECTS = 3
  # The IEND chunk with its CRC, which closes every complete PNG.
  PNG_END = "IEND\xAEB`\x82".b
  # Store pages and search results stay well under this.
  MAX_BODY = 5.megabytes

  BodyTooLarge = Class.new(StandardError)

  # The body of a 200 response, following https redirects, or nil. Bodies
  # are read in chunks and dropped once they pass `max_bytes`, so a redirect
  # to an oversized file never sits in memory whole.
  def get(url, max_bytes: MAX_BODY, redirects_left: MAX_REDIRECTS)
    body = +""
    response = connection.get(url) do |request|
      request.options.on_data = proc do |chunk, received|
        raise BodyTooLarge if received > max_bytes

        body << chunk
      end
    end
    location = response.headers["location"].to_s

    if response.status.in?(300..399)
      get(location, max_bytes:, redirects_left: redirects_left - 1) if redirects_left.positive? && location.start_with?("https://")
    elsif response.status == 200
      body
    end
  rescue Faraday::Error, BodyTooLarge => e
    Rails.logger.info("Account logo request failed: url=#{url} error=#{e.class}: #{e.message}")
    nil
  end

  def json(url)
    body = get(url)
    JSON.parse(body) if body
  rescue JSON::ParserError
    nil
  end

  def icon(url, key:, source:, name: nil, auto: true)
    body = get(url, max_bytes: Account::LOGO_MAX_SIZE)&.b
    return if body.nil?

    size, content_type, extension = image_format(body)
    Account::LogoFetcher::Icon.new(key:, source:, name:, body:, size:, content_type:, extension:, auto:) if size.to_i >= MIN_SIZE
  end

  # Runs the lambdas in threads (the work is waiting on HTTP) and returns their results in order.
  def in_parallel(tasks)
    threads = tasks.map { |task| Thread.new { Rails.application.executor.wrap { task.call } } }
    ActiveSupport::Dependencies.interlock.permit_concurrent_loads { threads.map(&:value) }
  end

  private
    def connection
      @connection ||= Faraday.new(request: { open_timeout: 5, timeout: 10 })
    end

    # Reads the pixel width from the file header; formats we cannot size are
    # skipped, and so are files cut short (no end marker), which would be
    # stored as a broken logo.
    def image_format(body)
      if body.start_with?("\x89PNG\r\n\x1a\n".b) && body.byteslice(12, 4) == "IHDR" && body.end_with?(PNG_END)
        [ body.byteslice(16, 4).unpack1("N"), "image/png", "png" ]
      elsif body.start_with?("\x00\x00\x01\x00".b) && body.bytesize >= 6
        [ ico_width(body), "image/vnd.microsoft.icon", "ico" ]
      elsif body.start_with?("GIF8") && body.bytesize >= 8 && body.end_with?(";")
        [ body.byteslice(6, 2).unpack1("v"), "image/gif", "gif" ]
      elsif body.start_with?("\xFF\xD8".b) && body.end_with?("\xFF\xD9".b)
        [ jpeg_width(body), "image/jpeg", "jpg" ]
      end
    end

    # The widest image an ICO holds, counting only directory entries whose
    # image data is in the file; nil when the directory itself is cut short.
    def ico_width(body)
      count = body.byteslice(4, 2).unpack1("v")
      return if count.zero? || body.bytesize < 6 + count * 16

      widths = (0...count).filter_map do |i|
        entry = 6 + i * 16
        data_size, data_offset = body.byteslice(entry + 8, 8).unpack("VV")
        width = body.getbyte(entry)
        # A width byte of 0 means 256px.
        (width.zero? ? 256 : width) if data_size.positive? && data_offset + data_size <= body.bytesize
      end
      widths.max
    end

    # Walks the JPEG segments to the start-of-frame one, which holds the dimensions.
    def jpeg_width(body)
      position = 2
      while position + 9 <= body.bytesize && body.getbyte(position) == 0xFF
        marker = body.getbyte(position + 1)
        return body.byteslice(position + 7, 2).unpack1("n") if marker.between?(0xC0, 0xCF) && ![ 0xC4, 0xC8, 0xCC ].include?(marker)

        position += 2 + body.byteslice(position + 2, 2).unpack1("n")
      end
    end
end
