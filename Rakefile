require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "fastlane/lib"
  t.libs << "fastlane/spec"
  t.test_files = FileList["fastlane/spec/*_test.rb"]
  t.warning = false
end

task default: :test
