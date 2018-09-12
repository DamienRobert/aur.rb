require 'aur/version'
require 'aur/config'
require 'aur/aur_rpc'
require 'aur/db'
require 'aur/repos'
require 'aur/versions'
require 'aur/devtools'
require 'aur/makepkg'
require 'aur/packages'

=begin
aur=Archlinux::AurPackageList.new([])
l=aur.install("pacaur")

aur=Archlinux.config.db.packages
aur.update?
=end

# TODO:
# --devel switch?
# aur search cache
# repo list of foreign packages
# view only when updated/new
# confirm before installing or updating pkgver (this is somewhat orthogonal to exiting when view return false since we may want to not view the files)
# cli
# tests
