require 'helper'
require 'aur'

class TestAur < Minitest::Test

  def test_version
    version = Archlinux.const_get('VERSION')

    assert(!version.empty?, 'should have a VERSION constant')
  end

end
