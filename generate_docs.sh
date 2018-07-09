#!/bin/sh

# git describe --tags `git rev-list --tags --max-count=1`
VERSION="0.0.1"

jazzy \
  --clean \
  --author CodeEagle \
  --author_url https://selfstudio.app \
  --github_url https://github.com/CodeEagle/APlay \
  --github-file-prefix https://github.com/CodeEagle/APlay/tree/v$VERSION \
  --module-version $VERSION \
  --xcodebuild-arguments -scheme,APlay \
  --module APlay \
  --output docs/
