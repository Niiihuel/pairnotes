# frozen_string_literal: true

require 'pathname'
require 'rexml/document'
require 'json'
require 'xcodeproj'

# Structural checks available on Linux. They do not compile Apple SDK sources.
root = Pathname.new(__dir__).join('../..').realpath
Dir.chdir(root)
project = Xcodeproj::Project.open('PairNotes.xcodeproj')
checks = 0
check = lambda do |condition, message|
  abort "Project validation failed: #{message}" unless condition
  checks += 1
end

expected_sources = {
  'PairNotes' => ['PairNotes/App/**/*.swift', 'PairNotes/Features/**/*.swift',
                  'PairNotes/Canvas/**/*.swift', 'PairNotes/Services/**/*.swift', 'PairNotes/Widgets/SharedSnapshot/**/*.swift'],
  'PairNotesWidgets' => ['PairNotes/Widgets/**/*.swift'],
  'PairNotesCore' => ['PairNotes/Core/**/*.swift'],
  'PairNotesNativeTests' => ['PairNotes/Tests/NativeTests/**/*.swift']
}
targets = project.targets.to_h { |target| [target.name, target] }
check.call(targets.keys.sort == expected_sources.keys.sort, 'unexpected or missing targets')
expected_sources.each do |name, patterns|
  expected = patterns.flat_map { |pattern| Dir.glob(pattern) }.sort.uniq
  actual = targets.fetch(name).source_build_phase.files_references.map do |reference|
    reference.real_path.relative_path_from(root).to_s
  end.sort
  check.call(!expected.empty? && actual == expected, "source membership differs for #{name}")
  targets.fetch(name).build_configurations.each do |configuration|
    settings = configuration.build_settings
    check.call(settings['IPHONEOS_DEPLOYMENT_TARGET'] == '26.0', "deployment target for #{name}/#{configuration.name}")
    check.call(settings['SUPPORTED_PLATFORMS'].split.sort == %w[iphoneos iphonesimulator], "platforms for #{name}/#{configuration.name}")
  end
end

project.files.each do |reference|
  path = reference.path.to_s
  check.call(!path.match?(%r{/SDKs/[^/]+\.sdk/}), "SDK version hard-coded in #{path}")
  next unless path == 'System/Library/Frameworks/Foundation.framework'

  check.call(reference.source_tree == 'SDKROOT', 'Foundation must resolve through the selected SDK')
end

core = targets.fetch('PairNotesCore')
app = targets.fetch('PairNotes')
widget = targets.fetch('PairNotesWidgets')
tests = targets.fetch('PairNotesNativeTests')
expected_packages = {
  'https://github.com/google/GoogleSignIn-iOS.git' => '9.2.0'
}
packages = project.root_object.package_references
check.call(packages.size == expected_packages.size, 'unexpected SDK packages')
packages.each do |package|
  check.call(package.requirement == { 'kind' => 'exactVersion', 'version' => expected_packages[package.repositoryURL] }, 'SDK versions must be exact and reviewed')
end
check.call(app.package_product_dependencies.map(&:product_name) == %w[GoogleSignIn], 'only Google Sign-In belongs to the app')
[core, widget, tests].each do |target|
  check.call(target.package_product_dependencies.empty?, "#{target.name} must not link service SDKs")
end
check.call(project.files.none? { |file| file.path.to_s.include?('GoogleService-Info') }, 'no abandoned Firebase configuration')
catalog_path = 'PairNotes/App/Assets.xcassets'
check.call(File.directory?(catalog_path), 'app asset catalog must exist')
targets.each_value do |target|
  catalogs = target.resources_build_phase.files_references.count { |reference| reference.path == catalog_path }
  check.call(catalogs == (target == app ? 1 : 0), "app assets resource membership for #{target.name}")
end
app.build_configurations.each do |configuration|
  check.call(configuration.build_settings['ASSETCATALOG_COMPILER_APPICON_NAME'] == 'AppIcon', "app icon selection for #{configuration.name}")
end
widget.build_configurations.each do |configuration|
  check.call(configuration.build_settings['ASSETCATALOG_COMPILER_APPICON_NAME'].nil?, 'widget must not select the app icon')
end
icon_set = File.join(catalog_path, 'AppIcon.appiconset')
icon_manifest = File.join(icon_set, 'Contents.json')
check.call(File.file?(icon_manifest), 'app icon manifest must exist')
icon_images = JSON.parse(File.read(icon_manifest)).fetch('images')
check.call(icon_images.any? { |image| image['filename'] && File.file?(File.join(icon_set, image['filename'])) }, 'app icon manifest must reference an existing image')
core.build_configurations.each do |configuration|
  check.call(configuration.build_settings['MACH_O_TYPE'] == 'staticlib', 'core must remain static')
  check.call(configuration.build_settings['APPLICATION_EXTENSION_API_ONLY'] == 'YES', 'core must be extension-safe')
end
[app, widget, tests].each do |target|
  check.call(target.dependencies.any? { |dependency| dependency.target == core }, "#{target.name} must depend on core")
  check.call(target.frameworks_build_phase.files_references.include?(core.product_reference), "#{target.name} must link core")
end
check.call(app.dependencies.any? { |dependency| dependency.target == widget }, 'app must depend on its widget')
check.call(app.copy_files_build_phases.any? do |phase|
  phase.dst_subfolder_spec == '13' && phase.files_references.include?(widget.product_reference)
end, 'widget must be embedded as a plug-in')
check.call(tests.dependencies.any? { |dependency| dependency.target == app }, 'native tests must depend on their host')
tests.build_configurations.each do |configuration|
  check.call(configuration.build_settings['TEST_HOST'] == '$(BUILT_PRODUCTS_DIR)/PairNotes.app/PairNotes', 'native test host')
  check.call(configuration.build_settings['BUNDLE_LOADER'] == '$(TEST_HOST)', 'native bundle loader')
end

scheme = REXML::Document.new(File.read('PairNotes.xcodeproj/xcshareddata/xcschemes/PairNotes.xcscheme'))
scheme.elements.each('//BuildableReference') do |reference|
  target = targets.values.find { |candidate| candidate.uuid == reference.attributes['BlueprintIdentifier'] }
  check.call(!target.nil?, 'scheme refers to an unknown target')
  check.call(reference.attributes['BuildableName'] == target.product_reference.path, 'scheme product name differs')
end
testable = scheme.elements['//TestAction/Testables/TestableReference']
check.call(testable && testable.attributes['skipped'] == 'NO', 'native tests must be enabled')
check.call(testable.elements['BuildableReference'].attributes['BlueprintIdentifier'] == tests.uuid, 'scheme must execute native tests')

Dir.glob('PairNotes/Core/**/*.swift').each do |path|
  check.call(!File.read(path).match?(/^import (UIKit|SwiftUI|PaperKit|PencilKit|WidgetKit|PhotosUI|Firebase\w*|GoogleSignIn)\b/), "platform dependency in #{path}")
end
Dir.glob('PairNotes/Widgets/**/*.swift').each do |path|
  check.call(!File.read(path).match?(/^import (Firebase\w*|GoogleSignIn)\b/), "service SDK dependency in #{path}")
end

puts "#{checks} structural project checks passed. Apple SDK compilation was not performed."
