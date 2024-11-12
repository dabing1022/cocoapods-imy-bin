#!/bin/bash

rm -rf cocoapods-imy-bin-*.gem
git add .
gem build cocoapods-imy-bin.gemspec
sudo gem uninstall cocoapods-imy-bin
sudo gem install cocoapods-imy-bin-*.gem