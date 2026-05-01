# frozen_string_literal: true

require_relative "lib/dependency_update/version"

Gem::Specification.new do |spec|
  spec.name = "dependency-update"
  spec.version = DependencyUpdate::VERSION
  spec.authors = ["Rene van Lieshout"]
  spec.email = ["rene@lico.nl"]
  spec.summary = "Update Ruby, Yarn, and Importmap dependencies with a cooldown period"
  spec.homepage = "https://forgejo.lico.nl/rvanlieshout/dependency-update"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  spec.files = Dir["lib/**/*.rb", "exe/*"]
  spec.executables = ["dependency_update"]
  spec.require_paths = ["lib"]
end
