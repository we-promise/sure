#!/usr/bin/env ruby
# frozen_string_literal: true

%w[json yaml].each { |library| require library }

ROOT = File.expand_path("..", __dir__)
WORKFLOW_PATH = File.join(ROOT, ".github/workflows/preview-deploy.yml")
LOCKFILE_PATH = File.join(ROOT, "workers/preview/package-lock.json")
PINNED_ACTION = /\A[^@\s]+@[a-f0-9]{40}\z/
EXPECTED_PERMISSIONS = { "actions" => "read", "contents" => "read", "pull-requests" => "write", "deployments" => "write" }.freeze
EXPECTED_SECRET_ENV = %w[CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_API_TOKEN CLOUDFLARE_WORKERS_SUBDOMAIN].freeze
REQUIRED_PREPARE_LINES = [
  'cp trusted/workers/preview/package.json "$preview_dir/package.json"',
  'cp trusted/workers/preview/package-lock.json "$preview_dir/package-lock.json"',
  'cp trusted/workers/preview/tsconfig.json "$preview_dir/tsconfig.json"',
  'cp trusted/workers/preview/wrangler.toml "$preview_dir/wrangler.toml"',
  'cp -R pr/workers/preview/src "$preview_dir/src"',
  'image = \"${GITHUB_WORKSPACE}/pr/Dockerfile.preview\"',
  "npm ci --ignore-scripts --no-audit --no-fund"
].freeze

def fail_check(message)
  warn "preview-deploy security check failed: #{message}"
  exit 1
end

def assert(value, message)
  fail_check(message) unless value
end

def step!(steps, name)
  steps.find { |step| step["name"] == name } || fail_check("missing #{name.inspect} step")
end

def run(step)
  step.fetch("run", "")
end

def assert_run_includes(step, *needles)
  script = run(step)
  needles.each { |needle| assert(script.include?(needle), "#{step["name"]} must include #{needle.inspect}") }
  script
end

workflow = YAML.safe_load_file(WORKFLOW_PATH, aliases: true)
lockfile = JSON.parse(File.read(LOCKFILE_PATH))
job = workflow.fetch("jobs").fetch("deploy-preview")
steps = job.fetch("steps")
step_names = steps.map { |step| step["name"] }
pr_checkout = step!(steps, "Checkout PR code")
trusted_checkout = step!(steps, "Checkout trusted preview tooling")
prepare = step!(steps, "Prepare trusted preview deploy workspace")
deploy = step!(steps, "Deploy to Cloudflare Containers")
wrangler = lockfile.fetch("packages").fetch("node_modules/wrangler")

{
  job.fetch("permissions") => EXPECTED_PERMISSIONS,
  job.dig("concurrency", "group") => "preview-deploy-${{ github.event.pull_request.number }}",
  job.dig("concurrency", "cancel-in-progress") => true,
  job.dig("env", "PR_NUMBER") => "${{ github.event.pull_request.number }}",
  job.dig("env", "HEAD_SHA") => "${{ github.event.pull_request.head.sha }}",
  pr_checkout.dig("with", "path") => "pr",
  pr_checkout.dig("with", "persist-credentials") => false,
  trusted_checkout.dig("with", "ref") => "${{ github.event.pull_request.base.sha }}",
  trusted_checkout.dig("with", "path") => "trusted",
  trusted_checkout.dig("with", "persist-credentials") => false,
  deploy.fetch("env").keys.sort => EXPECTED_SECRET_ENV,
  wrangler.dig("bin", "wrangler") => "bin/wrangler.js"
}.each { |actual, expected| assert(actual == expected, "expected #{actual.inspect} to equal #{expected.inspect}") }

assert(lockfile.dig("packages", "", "devDependencies", "wrangler"), "Wrangler must stay a root dev dependency")
assert(lockfile.fetch("lockfileVersion") >= 3, "preview tooling lockfile must preserve npm ci integrity metadata")
assert(wrangler.fetch("resolved").start_with?("https://registry.npmjs.org/wrangler/-/wrangler-"), "Wrangler must resolve from npm registry")
assert(wrangler.fetch("integrity").start_with?("sha512-"), "Wrangler lockfile entry must keep npm integrity metadata")
assert(trusted_checkout.dig("with", "sparse-checkout").to_s.include?("workers/preview"), "trusted checkout must include preview tooling")
assert(step_names.compact.uniq == step_names.compact, "workflow step names must stay unique for security checks")
assert([ pr_checkout, trusted_checkout, prepare, deploy ].map { |step| steps.index(step) }.each_cons(2).all? { |left, right| left < right }, "checkout, preparation, and deploy steps must stay ordered")
assert(job.fetch("env").keys.none? { |name| name.start_with?("CLOUDFLARE_") }, "Cloudflare secrets must not be job-wide")
assert(EXPECTED_SECRET_ENV.all? { |name| deploy.fetch("env").fetch(name).start_with?("${{ secrets.") }, "deploy secret env must be sourced from GitHub secrets")

steps.each do |step|
  uses = step["uses"]
  assert(uses.start_with?("./") || uses.match?(PINNED_ACTION), "#{step["name"] || uses} must pin external actions") if uses
end

inline_scripts = steps.flat_map { |step| [ run(step), step.dig("with", "script") ] }.compact.join("\n")
assert(!inline_scripts.include?("${{ secrets."), "secrets must enter scripts through env")
assert(!inline_scripts.include?("${{ github.event.pull_request."), "PR fields must enter scripts through env")
assert(steps.none? { |step| step["working-directory"].to_s.match?(%r{\A(pr|workers/preview)(/|\z)}) }, "steps must not run from PR-controlled dirs")
assert(steps.none? { |step| run(step).include?("npx wrangler") }, "workflow must not use npx wrangler")

prepare_run = assert_run_includes(prepare, *REQUIRED_PREPARE_LINES)
assert(!prepare_run.include?("npm install"), "prepare step must not use npm install")
assert(!prepare_run.include?("CLOUDFLARE_API_TOKEN"), "prepare step must not receive Cloudflare secrets")
assert([ prepare, deploy ].all? { |step| run(step).include?("set -euo pipefail") }, "trusted setup and deploy scripts must fail closed")
assert(prepare_run.include?('preview_dir="$RUNNER_TEMP/sure-preview-worker"'), "trusted workspace must be created under RUNNER_TEMP")
assert(steps.select { |step| run(step).match?(/npm (ci|install)/) }.map { |step| step["name"] } == [ prepare["name"] ], "only prepare may install deploy tooling")

secret_steps = steps.select { |step| step.fetch("env", {}).then { |env| env.key?("CLOUDFLARE_API_TOKEN") || env.key?("CLOUDFLARE_ACCOUNT_ID") } }
assert(secret_steps.map { |step| step["name"] } == [ deploy["name"] ], "only deploy may receive Cloudflare secrets")
secret_steps.each do |step|
  assert(step["working-directory"].nil?, "#{step["name"]} must not run from a PR-controlled working directory")
  assert(!run(step).match?(/npx wrangler|npm (ci|install)/), "#{step["name"]} must not execute PR-controlled tooling with secrets")
end

assert_run_includes(deploy, 'cd "$RUNNER_TEMP/sure-preview-worker"', "./node_modules/.bin/wrangler deploy --config wrangler.toml", '--var "PR_NUMBER:${PR_NUMBER}"')
puts "preview-deploy security check passed"
