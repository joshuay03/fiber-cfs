# frozen_string_literal: true

require_relative "lib/fiber_cfs/version"

Gem::Specification.new do |spec|
  spec.name = "fiber-cfs"
  spec.version = FiberCFS::VERSION
  spec.authors = ["Joshua Young"]
  spec.email = ["djry1999@gmail.com"]

  spec.summary = "A Completely Fair Fiber Scheduler"
  spec.homepage = "https://github.com/joshuay03/fiber-cfs"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4.0-preview2"

  # spec.metadata["documentation_uri"] = "https://joshuay03.github.io/fiber-cfs/"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir["{lib}/**/*", "**/*.{gemspec,md,txt}"]
  spec.require_paths = ["lib"]

  spec.add_dependency "nio4r", "~> 2.7"
  spec.add_dependency "red-black-tree", "~> 0.1"
  spec.add_dependency "async-dns", "~> 1.3"
end
