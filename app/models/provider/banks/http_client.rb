require 'net/http'
require 'uri'
require 'json'

class Provider::Banks::HttpClient
  DEFAULT_TIMEOUT = 30
  DEFAULT_MAX_RETRIES = 2

  def initialize(base_url:, auth: nil, headers: {}, timeout: DEFAULT_TIMEOUT, max_retries: DEFAULT_MAX_RETRIES)
    @base_url = base_url.chomp('/')
    @auth = auth
    @default_headers = headers
    @timeout = timeout
    @max_retries = max_retries
  end

  def get(path, query: {}, headers: {})
    request(:get, path, query: query, headers: headers)
  end

  def post(path, json: nil, form: nil, headers: {})
    request(:post, path, json: json, form: form, headers: headers)
  end

  private
    def request(method, path, query: {}, json: nil, form: nil, headers: {})
      url = URI.join(@base_url + '/', path.sub(/^\//, ''))
      http = Net::HTTP.new(url.host, url.port)
      http.use_ssl = (url.scheme == 'https')
      http.read_timeout = @timeout

      req_class = case method
                  when :get then Net::HTTP::Get
                  when :post then Net::HTTP::Post
                  else
                    raise ArgumentError, "Unsupported method: #{method}"
                  end

      if query.present?
        q = URI.decode_www_form(url.query.to_s) + query.to_a
        url.query = URI.encode_www_form(q)
      end

      req = req_class.new(url.request_uri)

      merged_headers = { 'User-Agent' => 'Sure Finance Bank Client' }.merge(@default_headers || {}).merge(headers || {})
      merged_headers.each { |k, v| req[k] = v }
      @auth&.apply!(req)

      if json
        req['Content-Type'] ||= 'application/json'
        req.body = JSON.generate(json)
      elsif form
        req['Content-Type'] ||= 'application/x-www-form-urlencoded'
        req.body = URI.encode_www_form(form)
      end

      attempts = 0
      begin
        res = http.request(req)
        code = res.code.to_i

        if (200..299).include?(code)
          return parse_response(res)
        elsif code == 429 || (500..599).include?(code)
          attempts += 1
          raise Provider::Error.new("HTTP #{code} #{res.message}", details: safe_parse(res.body)) if attempts > @max_retries
          sleep compute_sleep(res, attempts)
          retry
        else
          raise Provider::Error.new("HTTP #{code} #{res.message}", details: safe_parse(res.body))
        end
      rescue Provider::Error
        raise
      rescue => e
        attempts += 1
        raise Provider::Error.new(e.message) if attempts > @max_retries
        sleep backoff_seconds(attempts)
        retry
      end
    end

    def parse_response(res)
      body = res.body.to_s
      begin
        JSON.parse(body, symbolize_names: true)
      rescue
        body
      end
    end

    def safe_parse(body)
      JSON.parse(body.to_s, symbolize_names: true)
    rescue
      body.to_s
    end

    def compute_sleep(res, attempts)
      retry_after = (res["Retry-After"].to_f rescue 0.0)
      return retry_after if retry_after > 0
      backoff_seconds(attempts)
    end

    def backoff_seconds(attempt)
      base = 0.5
      [base * (2 ** (attempt - 1)), 4.0].min
    end
end

