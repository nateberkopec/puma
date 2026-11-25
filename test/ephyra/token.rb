require "tempfile"
require_relative "../../lib/puma/state_file"

token = ARGV.fetch(0)
Tempfile.create("puma-state") do |file|
  state = Puma::StateFile.new
  state.control_auth_token = token
  state.save(file.path)
  read = Puma::StateFile.new
  read.load(file.path)
  raise "token came back as #{read.control_auth_token.inspect}" unless read.control_auth_token == token
end
