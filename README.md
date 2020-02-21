# aur.rb

* [Homepage](https://github.com/DamienRobert/aur.rb#readme)
* [Issues](https://github.com/DamienRobert/aur.rb/issues)
* [Documentation](http://rubydoc.info/gems/aur.rb)
* [Email](mailto:Damien.Olivier.Robert+gems at gmail.com)

[![Gem Version](https://img.shields.io/gem/v/aur.rb.svg)](https://rubygems.org/gems/aur.rb)

## Description

A set of utilities to handle archlinux packages databases and aur
installation.

## Features

## Examples

    require 'aur.rb'

## Requirements

## Install

    $ gem install aur.rb

## Notes

There are three ways to install packages. The first is to simply use
`makepkg -si`. Here aur dependency packages built need to be installed
because `pacman` won't find them. So it may be cause for conflict.

The other way is to build dependency packages and add them to a database.
This allows further call to `makepkg -s` to find them if they are needed to
build a particular package. It may still cause conflict because they are
installed against the full system.

The last way is to build in a chroot. Here a database is needed too so the
chroot can access to the previously built dependency packages.

Adding a database require modifying `pacman.conf`, but `aur.rb` will
generate a temporary `pacman.conf` with the current database location
and use that when needed.

With this feature it is easy to simulate `checkupdates` too.

## Copyright

Copyright © 2018–2020 Damien Robert

MIT License. See [LICENSE.txt](./LICENSE.txt) for details.
