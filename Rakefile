require 'rake'

begin
  require 'rubygems/tasks'
  Gem::Tasks.new(sign: {checksum: true, pgp: true},
    scm: {status: true}) do |tasks|
    tasks.console.command = 'pry'
  end
rescue LoadError => e
  warn e.message
end

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
task :doc => :yard

begin
  require 'dr/rake_gems'
  Gem::MyTasks.new
rescue LoadError => e
  warn e.message
end

