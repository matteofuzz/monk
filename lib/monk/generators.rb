require_relative "generator"

# Monk's own modules, one generator each (docs/adr/0017). Loaded in
# dependency order only for readability: the registry resolves
# dependencies itself.
%w[base postgres redis mail auth jobs websocket live].each do |name|
  path = File.expand_path("generators/#{name}.rb", __dir__)
  require path if File.exist?(path)
end
