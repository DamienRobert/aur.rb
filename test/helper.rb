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
