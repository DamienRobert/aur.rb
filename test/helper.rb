## Uncomment if you want to run a test directly without running
## `bundle exec ruby -I test test/test_...rb`
## (another solution if 'bundler/setup' is called on the Rakefile is to use
## `rake test TEST=test/test_...rb`)
# begin
#   require 'bundler/setup'
# rescue LoadError => error
#   warn "Could not setup bundler: #{error.message}"
# end

require 'minitest/autorun'

## Uncomment to launch pry on a failure
#require 'pry-rescue/minitest'

begin
  require 'minitest/reporters'
  Minitest::Reporters.use! Minitest::Reporters::DefaultReporter.new
  #Minitest::Reporters.use! Minitest::Reporters::SpecReporter.new
  #Minitest::Reporters.use! Minitest::Reporters::ProgressReporter.new
rescue LoadError => error
  warn "minitest/reporters not found, not changing minitest reporter: #{error}"
end
