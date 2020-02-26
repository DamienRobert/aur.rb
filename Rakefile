## Uncomment to use `rake` directly rather than `bundle exec rake`
#begin
#  require 'bundler/setup'
#rescue LoadError => e
#  warn "Could not setup bundler: #{e.message}"
#end
require 'rake'

require 'rake/testtask'
Rake::TestTask.new do |test|
  test.libs << 'test'
  test.pattern = 'test/**/test_*.rb'
  test.verbose = true
end

begin
  require 'yard'
  YARD::Rake::YardocTask.new
rescue LoadError => e
  task :yard do
    warn e.message
  end
end
desc 'Generate docs'
task :doc => :yard

begin
  require 'dr/rake_gems'
  Gem::MyTasks.new
rescue LoadError => e
  warn e.message
end

task :default => :test
