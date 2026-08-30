require "bundler/gem_tasks"
require "rspec/core/rake_task"
RSpec::Core::RakeTask.new(:test)

begin
  require "cookstyle/chefstyle"
  require "rubocop/rake_task"
  RuboCop::RakeTask.new(:style) do |task|
    task.options += ["--display-cop-names", "--no-color"]
  end
rescue LoadError
  puts "cookstyle/chefstyle is not available. (sudo) gem install cookstyle to do style checking."
end

begin
  require "yard"

  # Options and the file list live in .yardopts so that a bare `yard` from the
  # command line produces exactly what `rake docs` does.
  YARD::Rake::YardocTask.new(:docs)

  desc "List anything in lib/ that is still undocumented"
  task :doc_coverage do
    sh "yard stats --list-undoc"
  end
rescue LoadError
  puts "yard is not available. (sudo) gem install yard to generate documentation."
end

namespace :integration do
  # Deliberately not part of any default task: these create real servers in a
  # real Hetzner Cloud project, and cost real money.
  desc "Run the integration suites against Hetzner Cloud (requires HCLOUD_TOKEN)"
  task :test do
    Dir.chdir("integration") { sh "bundle exec kitchen test --concurrency 4" }
  end

  desc "Destroy anything the integration suites left behind"
  task :destroy do
    Dir.chdir("integration") { sh "bundle exec kitchen destroy --concurrency 4" }
  end

  desc "List the integration suites"
  task :list do
    Dir.chdir("integration") { sh "bundle exec kitchen list" }
  end
end

task default: %i{test style}
