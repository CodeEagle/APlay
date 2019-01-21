Pod::Spec.new do |s|
  s.name             = 'APlay'
  s.version          = '0.1.0'
  s.summary          = 'A Better(Maybe) iOS Audio Stream & Play Swift Framework.'
  s.swift_version = '4.2'
  s.description      = <<-DESC
A Better(Maybe) iOS Audio Stream & Play Swift Framework
                       DESC

  s.homepage         = 'https://github.com/CodeEagle/APlay'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'CodeEagle' => 'stasura@hotmail.com' }
  s.source           = { :git => 'https://github.com/CodeEagle/APlay.git', :tag => s.version.to_s }

  s.platform = :ios
  s.ios.deployment_target = '8.0'

  s.exclude_files = 'APlay/Info.plist'
  s.source_files = 'APlay/**/*'
end
