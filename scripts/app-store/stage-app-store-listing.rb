#!/usr/bin/env ruby
# frozen_string_literal: true

# Stages distribution/app-store/listing.json and its screenshots into App Store Connect. It never submits for review.
#
#   ruby scripts/app-store/stage-app-store-listing.rb --validate-only
#   ruby scripts/app-store/stage-app-store-listing.rb --dry-run [--build-number N] [--screenshots DIR]
#   ruby scripts/app-store/stage-app-store-listing.rb --apply --build-number N --screenshot-set DIR
#
# --screenshot-set takes the Screenshots workflow's artifact (listing-screenshots-<fingerprint>) as it downloads and
# orders it for App Store Connect (GatefoldListing.arrange). --screenshots takes folders already named NN-name.png.
#
# {{name}} in listing.json is filled from distribution/app-store/identity.json. While no name is chosen, a validation
# or dry run fills it with "Gatefold" and says so; --apply refuses until identity.json names the app and says its
# icon is in, and until every screenshot folder holds the release's screenshots (screenshots.yml's artifacts).
#
# Credentials come from the environment: ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_BASE64 (the base64 of the .p8 key).
# Review details read GATEFOLD_REVIEW_DEMO_EMAIL and GATEFOLD_REVIEW_DEMO_PASSWORD (the demo PocketBook Cloud account)
# and, if set, APP_REVIEW_CONTACT_EMAIL and APP_REVIEW_CONTACT_PHONE. Secrets are never printed.
#
# Vendored from spoonjoy/spoonjoy-apple scripts/stage-app-store-listing.rb at ae4b5c4c5be9 (iOS only here).

require "optparse"
require "tmpdir"
require_relative "lib/app_store_listing"
require_relative "lib/gatefold_listing"

root = File.expand_path("../..", __dir__)
options = { mode: nil, build_number: nil, listing: File.join(root, "distribution/app-store/listing.json"),
            identity: File.join(root, "distribution/app-store/identity.json"), screenshots: nil, screenshot_set: nil }
OptionParser.new do |opts|
  opts.on("--validate-only") { options[:mode] = :validate }
  opts.on("--dry-run") { options[:mode] = :dry_run }
  opts.on("--apply") { options[:mode] = :apply }
  opts.on("--build-number N") { |value| options[:build_number] = value.strip.empty? ? nil : value.strip }
  opts.on("--listing PATH") { |value| options[:listing] = value }
  opts.on("--identity PATH") { |value| options[:identity] = value }
  opts.on("--screenshots DIR") { |value| options[:screenshots] = value }
  opts.on("--screenshot-set DIR") { |value| options[:screenshot_set] = value }
end.parse!
abort "Choose --validate-only, --dry-run or --apply" unless options[:mode]

raw = JSON.parse(File.read(options[:listing]))
identity = JSON.parse(File.read(options[:identity]))
listing, missing = AppStoreListing.with_identity(raw, identity)
unless missing.empty?
  abort "identity.json has no #{missing.join(', ')} yet: a real staging waits for the new name." if options[:mode] == :apply

  warn "::warning::identity.json has no #{missing.join(', ')} yet; checking with the name \"Gatefold\" in its place."
  listing, = AppStoreListing.with_identity(raw, identity.merge("name" => "Gatefold"))
end
abort "identity.json says the new icon is not in the app yet: a real staging waits for it." if options[:mode] == :apply && identity["icon"] != true

# Without screenshots (a validation, or a dry run before the release's shots exist) every folder is empty.
shots_root = options[:screenshots] || Dir.mktmpdir("gatefold-screenshots")
if options[:screenshot_set]
  spec = JSON.parse(File.read(File.join(root, "screenshots/spec.json")))
  problems = GatefoldListing.arrange(options[:screenshot_set], spec, listing, shots_root)
  unless problems.empty?
    warn "The screenshot set is not complete:"
    problems.each { |problem| warn "- #{problem}" }
    exit 1
  end
end
listing.fetch("screenshots").each_key { |folder| FileUtils.mkdir_p(File.join(shots_root, folder)) }

errors = AppStoreListing.validate(listing, shots_root) + GatefoldListing.problems(listing)
unless errors.empty?
  warn "The listing is not valid:"
  errors.each { |error| warn "- #{error}" }
  exit 1
end
screenshots = AppStoreListing.local_screenshots(listing, shots_root)
screenshots.each { |folder, files| puts "#{folder}: #{files.length} screenshot(s)" }
if options[:mode] == :apply && (empty = screenshots.select { |_, files| files.empty? }.keys).any?
  abort "No screenshots for #{empty.join(', ')}: run Screenshots on the release commit and pass its artifact with --screenshot-set."
end
creative_assets = AppStoreListing.local_creative_assets(listing, shots_root)
creative_assets.each { |type, file| puts "#{type}: #{File.basename(file['path'])}" }
if options[:mode] == :validate
  puts "The listing is valid."
  exit 0
end

%w[ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_BASE64].each do |name|
  abort "Missing #{name}" if ENV[name].to_s.empty?
end
abort "--apply needs --build-number" if options[:mode] == :apply && options[:build_number].nil?

client = AppStoreListing::Client.new(
  key_id: ENV.fetch("ASC_KEY_ID"), issuer_id: ENV.fetch("ASC_ISSUER_ID"),
  private_key_pem: Base64.strict_decode64(ENV.fetch("ASC_KEY_BASE64").strip)
)
reader = AppStoreListing::Reader.new(client, listing)
env = ->(name) { ENV[name].to_s.empty? ? nil : ENV[name] }
secrets = {
  "demoAccountName" => env.call("GATEFOLD_REVIEW_DEMO_EMAIL"),
  "demoAccountPassword" => env.call("GATEFOLD_REVIEW_DEMO_PASSWORD"),
  "contactEmail" => env.call("APP_REVIEW_CONTACT_EMAIL"),
  "contactPhone" => env.call("APP_REVIEW_CONTACT_PHONE")
}.compact
warn "::warning::No demo account secrets: review details will not include the demo account." unless secrets["demoAccountName"]
if options[:mode] == :apply && listing.dig("review", "demoAccountRequired") && !secrets["demoAccountPassword"]
  abort "The listing says App Review needs the demo account, and GATEFOLD_REVIEW_DEMO_PASSWORD is not set."
end

begin
  snapshot = reader.snapshot(build_number: options[:build_number])
rescue AppStoreListing::Error => e
  abort e.message
end
steps = AppStoreListing.plan(listing: listing, snapshot: snapshot, screenshots: screenshots, secrets: secrets,
                             creative_assets: creative_assets)
puts "App Store Connect app #{reader.app_id}: #{steps.length} change(s)"
puts AppStoreListing.describe(steps)
if options[:mode] == :dry_run
  puts "Dry run: nothing was written."
  exit 0
end

AppStoreListing::Executor.new(client, reader.app_id).run(steps)
puts "Staged. Review the listing in App Store Connect and submit it there; this script never submits."
