# frozen_string_literal: true

# Run: ruby scripts/app-store/test/gatefold_listing_test.rb
#
# Gatefold's own rules for distribution/app-store/listing.json, on top of the vendored stager's checks.
require "minitest/autorun"
require "json"
require "tmpdir"
require_relative "../lib/app_store_listing"
require_relative "../lib/gatefold_listing"

class GatefoldListingTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)

  def raw_listing
    @raw_listing ||= JSON.parse(File.read(File.join(ROOT, "distribution/app-store/listing.json")))
  end

  def identity
    @identity ||= JSON.parse(File.read(File.join(ROOT, "distribution/app-store/identity.json")))
  end

  def filled(name = "Bookmark")
    AppStoreListing.with_identity(raw_listing, { "name" => name }).first
  end

  # The name is being chosen in another lane: every place it goes is a placeholder, filled from identity.json.
  def test_the_name_is_a_placeholder_wherever_it_appears
    strip = ->(v) { v.is_a?(Hash) ? v.reject { |k, _| k.start_with?("_") }.transform_values(&strip) : v }
    text = JSON.generate(strip.call(raw_listing))
    refute_match(/\bGatefold\b/, text.gsub(%r{ourostack(\.github\.io)?/gatefold}, ""), "write {{name}}, not the old name")
    assert_equal "{{name}}", raw_listing.dig("localizations", "en-US", "name")
    assert_includes raw_listing.dig("review", "notes"), "{{name}}"
  end

  def test_with_identity_fills_every_placeholder_and_names_what_it_could_not
    out, missing = AppStoreListing.with_identity(raw_listing, { "name" => "Bookmark" })
    refute_match(/\{\{/, JSON.generate(out))
    assert_equal [], missing
    assert_equal "Bookmark", out.dig("localizations", "en-US", "name")
    _, missing = AppStoreListing.with_identity(raw_listing, { "name" => nil })
    assert_equal ["name"], missing
  end

  def test_identity_json_says_what_is_still_to_choose
    assert identity.key?("name"), "identity.json holds the name, null until it is chosen"
    assert identity.key?("icon"), "and whether the new icon is in the app"
  end

  def test_a_listing_with_its_longest_name_still_fits
    long = filled("N" * 30)
    errors = Dir.mktmpdir do |dir|
      long.fetch("screenshots").each_key { |folder| Dir.mkdir(File.join(dir, folder)) }
      AppStoreListing.validate(long, dir)
    end
    assert_equal [], errors
  end

  # Guideline 2.3.7 and 5.2.1: no one else's trademark in the name, subtitle or keywords; PocketBook appears only as
  # what the app works with, alongside the non-affiliation line.
  def test_no_one_elses_trademark_in_the_name_subtitle_or_keywords
    assert_equal [], GatefoldListing.trademark_problems(filled)
    bad = filled
    bad["localizations"]["en-US"]["keywords"] = "pocketbook,kindle,epub"
    assert_equal 2, GatefoldListing.trademark_problems(bad).length
  end

  def test_pocketbook_in_the_description_comes_with_the_non_affiliation_line
    bad = filled
    bad["localizations"]["en-US"]["description"] = "Reads your PocketBook Cloud library."
    assert_includes GatefoldListing.trademark_problems(bad).join, "not affiliated"
  end

  # Release builds send counts-only telemetry (docs/privacy/), so the listing may not say otherwise (5.1.1, 2.3.1).
  def test_the_listing_never_says_the_app_collects_nothing
    assert_equal [], GatefoldListing.claim_problems(filled)
    bad = filled
    bad["localizations"]["en-US"]["description"] += "\nNo tracking and no analytics."
    refute_empty GatefoldListing.claim_problems(bad)
  end

  # Guideline 2.1: App Review can reach every feature. Without an account through the bundled classics; with the
  # demo PocketBook Cloud account for sync. The notes say how to reach both.
  def test_review_notes_give_app_review_both_ways_in
    notes = filled.dig("review", "notes")
    ["Read Without an Account", "Try a Few Classics", "Sign In with PocketBook Cloud", "not affiliated"].each do |phrase|
      assert_includes notes, phrase
    end
    assert_equal true, raw_listing.dig("review", "demoAccountRequired")
    assert_nil raw_listing.dig("review", "contactEmail"), "the contact email comes from a secret, never the public repo"
  end

  # Every screenshot folder is one screenshots/spec.json renders, at the size App Store Connect takes for its type.
  def test_screenshot_folders_are_the_ones_the_pipeline_renders
    spec = JSON.parse(File.read(File.join(ROOT, "screenshots/spec.json")))
    rendered = spec.fetch("devices").values.to_h { |d| [d.fetch("folder"), d.fetch("canvas")] }
    raw_listing.fetch("screenshots").each do |folder, want|
      assert rendered.key?(folder), "#{folder} is in listing.json but screenshots/spec.json renders no such folder"
      assert_includes want.fetch("sizes"), rendered.fetch(folder), "#{folder}: spec.json's canvas is not a size App Store Connect takes"
    end
    assert raw_listing.fetch("screenshots").key?("iphone-6.9"), "App Store Connect requires 6.9-inch iPhone screenshots"
  end

  def test_free_with_no_purchases_and_rated_like_a_book_reader
    assert_equal "0.0", raw_listing.dig("price", "customerPrice")
    assert_equal "BOOKS", raw_listing.dig("categories", "primary")
    assert_equal "USES_THIRD_PARTY_CONTENT", raw_listing["contentRightsDeclaration"]
    answers = raw_listing.fetch("ageRating")
    assert_equal false, answers["unrestrictedWebAccess"]
    assert_equal false, answers["userGeneratedContent"]
  end

  # A real staging waits for the name and the icon: --apply refuses while identity.json has neither.
  def test_apply_refuses_until_the_name_and_icon_are_in
    require "open3"
    stager = File.join(ROOT, "scripts/app-store/stage-app-store-listing.rb")
    Dir.mktmpdir do |dir|
      unnamed = File.join(dir, "unnamed.json")
      File.write(unnamed, JSON.generate({ "name" => nil, "icon" => false }))
      out, status = Open3.capture2e(RbConfig.ruby, stager, "--apply", "--build-number", "1", "--identity", unnamed)
      refute status.success?
      assert_includes out, "waits for the new name"
      no_icon = File.join(dir, "no-icon.json")
      File.write(no_icon, JSON.generate({ "name" => "Bookmark", "icon" => false }))
      out, status = Open3.capture2e(RbConfig.ruby, stager, "--apply", "--build-number", "1", "--identity", no_icon)
      refute status.success?
      assert_includes out, "icon is not in the app yet"
    end
  end

  # A Screenshots artifact becomes NN-<scene>.png per folder, in spec.json's scene order, checked against SHA256SUMS.
  def test_arrange_orders_a_screenshot_set_for_app_store_connect
    spec = { "devices" => { "iphone" => { "folder" => "iphone-6.3" } },
             "scenes" => [{ "id" => "catch-up", "devices" => ["iphone"] }, { "id" => "spread", "devices" => ["ipad"] },
                          { "id" => "shelf", "devices" => ["iphone"] }] }
    listing = { "screenshots" => { "iphone-6.3" => {} } }
    Dir.mktmpdir do |dir|
      set = File.join(dir, "set")
      FileUtils.mkdir_p(File.join(set, "iphone-6.3", "raw"))
      %w[catch-up shelf].each { |id| File.write(File.join(set, "iphone-6.3", "#{id}.png"), id) }
      File.write(File.join(set, "iphone-6.3", "raw", "shelf.png"), "raw")
      sums = %w[catch-up shelf].map { |id| "#{Digest::SHA256.hexdigest(id)}  iphone-6.3/#{id}.png" }
      File.write(File.join(set, "iphone-6.3", "SHA256SUMS"), sums.join("\n") + "\n")
      out = File.join(dir, "out")
      assert_equal [], GatefoldListing.arrange(set, spec, listing, out)
      assert_equal %w[01-catch-up.png 02-shelf.png], Dir.children(File.join(out, "iphone-6.3")).sort
      File.write(File.join(set, "iphone-6.3", "shelf.png"), "changed")
      assert_equal ["iphone-6.3/shelf.png does not match its SHA256SUMS line"],
                   GatefoldListing.arrange(set, spec, listing, File.join(dir, "out2"))
      File.delete(File.join(set, "iphone-6.3", "catch-up.png"))
      assert_includes GatefoldListing.arrange(set, spec, listing, File.join(dir, "out3")),
                      "iphone-6.3: the screenshot set has no catch-up.png"
    end
  end
end
