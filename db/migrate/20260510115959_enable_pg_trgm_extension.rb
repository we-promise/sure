class EnablePgTrgmExtension < ActiveRecord::Migration[7.2]
  def change
    enable_extension :pg_trgm unless extension_enabled?("pg_trgm")
  end
end
