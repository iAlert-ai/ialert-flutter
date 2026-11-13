Pod::Spec.new do |s|
  s.name             = 'ialert_flutter'
  s.version          = '0.8.0'
  s.summary          = 'iAlert push notifications for Flutter (iOS native side).'
  s.homepage         = 'https://ialert.ir'
  s.license          = { :type => 'Apache-2.0', :file => '../LICENSE' }
  s.author           = { 'iAlert' => 'support@ialert.ir' }
  s.source           = { :path => '.' }
  s.source_files     = 'ialert_flutter/Sources/ialert_flutter/**/*.swift'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.0'
end
