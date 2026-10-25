Pod::Spec.new do |s|
  s.name             = 'tdlib'
  s.version          = '1.8.69'
  s.summary          = 'Prebuilt TDLib for TG Media (read-only client).'
  s.description      = <<-DESC
TDLib xcframework produced by Swiftgram/TDLibFramework, release 1.8.69-025086e3
(sha256 65758175da552aabee45463698c6fb4553d614612df0cbd49c07d550eed46a41).
Verified offline: the ios-arm64 slice is a static archive (magic "!<arch>"),
packaged as TDLibFramework.framework with Headers/ and Modules/module.modulemap,
MinimumOSVersion 12.0. Because it is static, nothing has to be embedded into the
app bundle and no dynamic library has to be signed on device.
                       DESC
  s.homepage         = 'https://github.com/tdlib/td'
  s.license          = { :type => 'BSL-1.0', :text => 'Boost Software License 1.0. TDLib is Copyright (c) Telegram FZ-LLC.' }
  s.author           = { 'Telegram' => 'https://telegram.org' }
  s.source           = { :path => '.' }
  s.ios.deployment_target = '15.2'

  # Binary comes from scripts/fetch_tdlib.sh and is never committed.
  # CocoaPods default integration is static, which matches the static archive
  # inside the framework; no `use_frameworks!` and no embed phase required.
  s.vendored_frameworks = 'TDLibFramework.xcframework'

  # TDLib's C++ core needs libc++ and zlib; OpenSSL and other deps are baked in
  # by the upstream build, so no third-party pods are pulled in.
  s.libraries = 'c++', 'z'
  s.frameworks = 'Foundation', 'CoreFoundation', 'Security', 'CoreMedia', 'AVFoundation'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
  }
  s.user_target_xcconfig = {
    # The app never calls td_* from Objective-C, so without this the linker is
    # free to drop tdjson.o and dart:ffi would fail to resolve the symbols from
    # DynamicLibrary.process() at runtime.
    'OTHER_LDFLAGS' => '-Wl,-u,_td_create_client_id',
  }
end
