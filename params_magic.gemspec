$:.push File.expand_path("../lib", __FILE__)

# Maintain your gem's version:
require "params_magic/version"

# Describe your gem and declare its dependencies:
Gem::Specification.new do |s|
  s.name        = "params_magic"
  s.version     = ParamsMagic::VERSION
  s.authors     = ["Yecheng Xu"]
  s.email       = ["xyc0562@gmail.com"]
  s.homepage    = "TODO"
  s.summary     = "Helper methods for search & render in controller actions, plus helpers for building dynamic " +
      "active_model_serializer instances based on passed in parameters"
  s.description = "This is currently intended for internal use and may not come with support and much documentation."
  s.license     = "MIT"

  s.files = Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.rdoc"]
  s.test_files = Dir["test/**/*"]

  s.add_dependency 'rails', '~> 4.2.3'
  s.add_dependency 'kaminari'
  s.add_dependency 'active_model_serializers'

  s.add_development_dependency "sqlite3"
end
