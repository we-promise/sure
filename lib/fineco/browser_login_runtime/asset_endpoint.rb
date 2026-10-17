# frozen_string_literal: true

require "pathname"

module Fineco
  class BrowserLoginRuntime
    class AssetEndpoint
      MAX_ASSET_BYTES = 8 * 1024 * 1024
      CONTENT_TYPES = {
        ".css" => "text/css; charset=utf-8",
        ".js" => "text/javascript; charset=utf-8",
        ".json" => "application/json",
        ".png" => "image/png",
        ".svg" => "image/svg+xml",
        ".txt" => "text/plain; charset=utf-8",
        ".wasm" => "application/wasm"
      }.freeze

      def initialize(root:)
        @root = File.expand_path(root.to_s)
      end

      def call(env)
        return response(405) unless %w[GET HEAD].include?(env["REQUEST_METHOD"])

        path = normalized_path(env.fetch("PATH_INFO", ""))
        return response(404) unless path

        file = File.join(@root, path)
        root_stat = File.lstat(@root)
        return response(404) unless root_stat.directory? && !root_stat.symlink?

        components = path.split("/")
        parent = @root
        components[0...-1].each do |component|
          parent = File.join(parent, component)
          parent_stat = File.lstat(parent)
          return response(404) unless parent_stat.directory? && !parent_stat.symlink?
        end
        stat = File.lstat(file)
        return response(404) unless stat.file? && !stat.symlink? && stat.size <= MAX_ASSET_BYTES

        content_type = CONTENT_TYPES[File.extname(file)]
        return response(404) unless content_type

        body = env["REQUEST_METHOD"] == "HEAD" ? [] : [ File.binread(file) ]
        [ 200, headers(content_type, stat.size), body ]
      rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES, ArgumentError
        response(404)
      end

      private

        def normalized_path(path)
          return unless path.is_a?(String) && path.bytesize <= 512 && !path.include?("\\") && !path.include?("\0")

          decoded = Rack::Utils.unescape_path(path)
          components = decoded.split("/").reject(&:empty?)
          return if components.empty? || (components.first != "LICENSE.txt" && !%w[core vendor].include?(components.first))
          return if components.first == "LICENSE.txt" && components.length != 1
          return if components.any? { |part| part == "." || part == ".." }
          return unless components.all? { |part| part.match?(/\A[a-zA-Z0-9_.-]+\z/) }

          components.join("/")
        rescue ArgumentError
          nil
        end

        def headers(content_type, size)
          {
            "Content-Type" => content_type,
            "Content-Length" => size.to_s,
            "Cache-Control" => "no-store",
            "X-Content-Type-Options" => "nosniff",
            "Content-Security-Policy" => "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self' ws: wss:; worker-src 'self' blob:"
          }
        end

        def response(status)
          [ status, { "Content-Length" => "0", "Cache-Control" => "no-store", "X-Content-Type-Options" => "nosniff" }, [] ]
        end
    end
  end
end
