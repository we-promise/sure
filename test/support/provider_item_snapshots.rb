# frozen_string_literal: true

# HTML snapshots for the provider kit's view components. A snapshot is the
# provider's own partial rendered before it moved onto a component; the
# component must render the same HTML. A deliberate markup change re-records
# only the snapshots it touches. Record ids, random element ids and CSRF
# tokens are normalised, time is frozen by the test, and whitespace between and
# around tags is ignored (a component's template is indented differently).
# Set PROVIDER_ITEM_SNAPSHOTS=write to record a missing snapshot.
module ProviderItemSnapshots
  SNAPSHOT_DIR = Rails.root.join("test/components/provider_item/snapshots")

  UUID = /\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/
  RANDOM_ID = /\b([a-z]+)-\h{8}\b/
  CSRF = /(name="authenticity_token" value=|name="csrf-token" content=)"[^"]+"/

  private
    def assert_matches_provider_item_snapshot(name, html)
      path = SNAPSHOT_DIR.join("#{name}.html")
      normalised = normalise_provider_item_html(html)

      if !path.exist? && ENV["PROVIDER_ITEM_SNAPSHOTS"] == "write"
        path.write(normalised)
      end

      assert path.exist?, "no snapshot #{path.basename}; record it from the partial before the change"
      assert_equal path.read, normalised, "#{name} differs from its snapshot"
    end

    def normalise_provider_item_html(html)
      html.gsub(UUID, "UUID").gsub(RANDOM_ID, '\1-ID').gsub(CSRF, '\1"CSRF"')
          .gsub(/\s+/, " ").gsub(/>\s+/, ">").gsub(/\s+</, "<").gsub("><", ">\n<").strip + "\n"
    end
end
