require "tempfile"
require "yaml"
require_relative "../../lib/puma/state_file"

path = ARGV.fetch(0)
Tempfile.create("puma-state") do |file|
  state = Puma::StateFile.new
  state.running_from = path
  state.pid = Process.pid
  state.save(file.path)
  read = Puma::StateFile.new
  read.load(file.path)
  raise "Puma path mismatch: #{read.running_from.inspect}" unless read.running_from == path
  parsed = YAML.safe_load_file(file.path)
  raise "YAML path mismatch: #{parsed.fetch('running_from').inspect}" unless parsed.fetch("running_from") == path
  raise "PID mismatch" unless [read.pid, parsed.fetch("pid")].all? { |pid| pid.eql?(Process.pid) }
end
