require 'minitest/autorun'
require 'open3'
require_relative 'test_env'

Encoding.default_external = "UTF-8"
Encoding.default_internal = "UTF-8"

# Shared helper for scripts that should show usage and exit 1 when no args are given.
module ScriptUsageHelper
  BIN = File.expand_path("..", __dir__)

  def assert_usage_on_no_args(name, pattern = /[Uu]sage|Bruk/)
    path = File.join(BIN, name)
    out, status = Open3.capture2e(
      { "LANG" => "en_US.UTF-8", "LC_ALL" => "en_US.UTF-8" },
      "ruby", path
    )
    out = out.force_encoding("UTF-8")
    refute_equal 0, status.exitstatus, "expected non-zero exit, got 0\n#{out}"
    assert_match pattern, out, "expected usage message, got:\n#{out}"
  end

  def assert_usage_on_help(name, pattern = /[Uu]sage|Bruk/)
    path = File.join(BIN, name)
    out, _ = Open3.capture2e(
      { "LANG" => "en_US.UTF-8", "LC_ALL" => "en_US.UTF-8" },
      "ruby", path, "--help"
    )
    out = out.force_encoding("UTF-8")
    assert_match pattern, out, "expected usage message on --help, got:\n#{out}"
  end
end
