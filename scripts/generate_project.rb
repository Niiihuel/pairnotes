# frozen_string_literal: true
require 'xcodeproj'

# Run from repository root. The checked-in project needs no Ruby to open/build.
abort 'Run from the repository root' unless File.exist?('Package.swift')
if File.exist?('PairNotes.xcodeproj/project.pbxproj') && !ARGV.include?('--replace')
  abort 'Project already exists. Review local Xcode changes before using --replace.'
end
project = Xcodeproj::Project.new('PairNotes.xcodeproj')
base = project.main_group.new_file('Config/Base.xcconfig')
app = project.new_target(:application, 'PairNotes', :ios, '26.0')
widget = project.new_target(:app_extension, 'PairNotesWidgets', :ios, '26.0')
core = project.new_target(:framework, 'PairNotesCore', :ios, '26.0')
tests = project.new_target(:unit_test_bundle, 'PairNotesNativeTests', :ios, '26.0')
ui_tests = project.new_target(:ui_test_bundle, 'PairNotesUITests', :ios, '26.0')

# xcodeproj's built-in SDK table can name an older SDK that the selected Xcode
# no longer ships. Resolve Apple frameworks through the SDK chosen at build time.
project.files.select { |reference| reference.name == 'Foundation.framework' }.each do |reference|
  reference.source_tree = 'SDKROOT'
  reference.path = 'System/Library/Frameworks/Foundation.framework'
end

def add_sources(project, target, patterns)
  patterns.flat_map { |pattern| Dir.glob(pattern) }.sort.uniq.each do |path|
    reference = project.main_group.files.find { |file| file.path == path }
    target.add_file_references([reference || project.main_group.new_file(path)])
  end
end
add_sources(project, core, ['PairNotes/Core/**/*.swift'])
add_sources(project, app, ['PairNotes/App/**/*.swift', 'PairNotes/Features/**/*.swift', 'PairNotes/Canvas/**/*.swift', 'PairNotes/Services/**/*.swift', 'PairNotes/Widgets/SharedSnapshot/**/*.swift'])
add_sources(project, widget, ['PairNotes/Widgets/**/*.swift'])
add_sources(project, tests, ['PairNotes/Tests/NativeTests/**/*.swift'])
add_sources(project, ui_tests, ['PairNotes/Tests/UITests/**/*.swift'])
assets = project.main_group.new_file('PairNotes/App/Assets.xcassets')
app.resources_build_phase.add_file_reference(assets)
[[app, 'PairNotes/App/PrivacyInfo.xcprivacy'], [widget, 'PairNotes/Widgets/PrivacyInfo.xcprivacy']].each do |target, path|
  manifest = project.main_group.new_file(path)
  manifest.last_known_file_type = 'text.xml'
  target.resources_build_phase.add_file_reference(manifest)
end

# Google Sign-In belongs only to the app. The pure core and widget do not link it.
def add_package(project, target, url, version, products)
  package = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
  package.repositoryURL = url
  package.requirement = { 'kind' => 'exactVersion', 'version' => version }
  project.root_object.package_references << package
  products.each do |name|
    dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
    dependency.package = package
    dependency.product_name = name
    target.package_product_dependencies << dependency
    build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
    build_file.product_ref = dependency
    target.frameworks_build_phase.files << build_file
  end
end
add_package(project, app, 'https://github.com/google/GoogleSignIn-iOS.git', '9.2.0', %w[GoogleSignIn])

[app, widget, tests].each do |target|
  target.add_dependency(core)
  target.frameworks_build_phase.add_file_reference(core.product_reference)
end
tests.add_dependency(app)
ui_tests.add_dependency(app)
app.add_dependency(widget)
embed = app.new_copy_files_build_phase('Embed App Extensions')
embed.dst_subfolder_spec = '13'
embed.add_file_reference(widget.product_reference).settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

project.build_configurations.each do |config|
  config.base_configuration_reference = base
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '26.0'
end
project.targets.each do |target|
  target.build_configurations.each do |config|
    settings = config.build_settings
    settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
    settings['SWIFT_VERSION'] = '5.0'
    settings['IPHONEOS_DEPLOYMENT_TARGET'] = '26.0'
    settings['TARGETED_DEVICE_FAMILY'] = '1,2'
    settings['SUPPORTED_PLATFORMS'] = 'iphoneos iphonesimulator'
    settings['SUPPORTS_MACCATALYST'] = 'NO'
    settings['GENERATE_INFOPLIST_FILE'] = 'YES'
    settings['SWIFT_OPTIMIZATION_LEVEL'] = config.name == 'Debug' ? '-Onone' : '-O'
    settings['ENABLE_TESTABILITY'] = 'YES' if config.name == 'Debug'
    settings['PRODUCT_BUNDLE_IDENTIFIER'] = "$(PAIRNOTES_BUNDLE_ID).#{target.name}"
  end
end
app.build_configurations.each do |config|
  config.build_settings['PROVISIONING_PROFILE_SPECIFIER'] = '$(PAIRNOTES_APP_PROFILE_SPECIFIER)'
  config.build_settings.merge!('PRODUCT_BUNDLE_IDENTIFIER' => '$(PAIRNOTES_BUNDLE_ID)', 'INFOPLIST_FILE' => 'Config/App-Info.plist', 'GENERATE_INFOPLIST_FILE' => 'NO', 'CODE_SIGN_ENTITLEMENTS' => '$(APP_ENTITLEMENTS)', 'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/Frameworks'], 'ASSETCATALOG_COMPILER_APPICON_NAME' => 'AppIcon')
  config.build_settings['OTHER_LDFLAGS'] = ['$(inherited)', '-ObjC']
  config.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = ['$(inherited)', 'DEBUG'] if config.name == 'Debug'
end
widget.build_configurations.each do |config|
  config.build_settings['PROVISIONING_PROFILE_SPECIFIER'] = '$(PAIRNOTES_WIDGET_PROFILE_SPECIFIER)'
  config.build_settings.merge!('PRODUCT_BUNDLE_IDENTIFIER' => '$(PAIRNOTES_BUNDLE_ID).widgets', 'INFOPLIST_FILE' => 'Config/Widget-Info.plist', 'GENERATE_INFOPLIST_FILE' => 'NO', 'CODE_SIGN_ENTITLEMENTS' => '$(WIDGET_ENTITLEMENTS)', 'APPLICATION_EXTENSION_API_ONLY' => 'YES', 'SKIP_INSTALL' => 'YES', 'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks'])
end
core.build_configurations.each do |config|
  config.build_settings.merge!('MACH_O_TYPE' => 'staticlib', 'DEFINES_MODULE' => 'YES', 'SKIP_INSTALL' => 'YES', 'APPLICATION_EXTENSION_API_ONLY' => 'YES', 'CODE_SIGNING_ALLOWED' => 'NO')
end
tests.build_configurations.each do |config|
  config.build_settings.merge!('TEST_HOST' => '$(BUILT_PRODUCTS_DIR)/PairNotes.app/PairNotes', 'BUNDLE_LOADER' => '$(TEST_HOST)')
end
ui_tests.build_configurations.each do |config|
  config.build_settings['TEST_TARGET_NAME'] = 'PairNotes'
end
project.root_object.attributes['TargetAttributes'] ||= {}
project.root_object.attributes['TargetAttributes'][ui_tests.uuid] = { 'TestTargetID' => app.uuid }
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_build_target(tests, false)
scheme.add_build_target(ui_tests, false)
scheme.set_launch_target(app)
scheme.add_test_target(tests)
scheme.add_test_target(ui_tests)
scheme.save_as(project.path, 'PairNotes', true)
puts 'Generated PairNotes.xcodeproj: app, extension, static core, native tests and interaction UI tests (not compiled).'
