Pod::Spec.new do |s|
  s.name             = 'tdlib'
  s.version          = '1.8.69'
  s.summary          = 'Prebuilt TDLib for TG Media (read-only client).'
  s.description      = <<-DESC
TDLib xcframework produced by Swiftgram/TDLibFramework, release 1.8.69-025086e3.
Vendored so the Flutter build links the C JSON API without a custom Xcode target.
                       DESC
  s.homepage         = 'https://github.com/tdlib/td'
  s.license          = { :type => 'BSL-1.0', :text => 'Boost Software License 1.0. TDLib is Copyright (c) Telegram FZ-LLC.' }
  s.author           = { 'Telegram' => 'https://telegram.org' }
  s.source           = { :path => '.' }
  s.ios.deployment_target = '15.2'

  # Binary comes from scripts/fetch_tdlib.sh and is never committed.
  s.vendored_frameworks = 'TDLibFramework.xcframework'

  # TDLib's C++ core needs libc++ and zlib; OpenSSL is statically baked in by
  # the upstream build script.
  s.libraries = 'c++', 'z'
  s.frameworks = 'Foundation', 'CoreFoundation', 'Security', 'CoreMedia', 'AVFoundation'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
  }
  s.user_target_xcconfig = {
    # Keeps td_* symbols in the final binary even when no Swift code calls them,
    # so dart:ffi can resolve them from DynamicLibrary.process().
    'OTHER_LDFLAGS' => '-Wl,-u,_td_create_client_id',
  }
end
