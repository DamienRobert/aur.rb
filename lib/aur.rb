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

aur=Archlinux::AurPackageList.new(Archlinux.config.db.packages)
aur.do_update
=end

# TODO:
# --devel
# aur provides
# @ignore
