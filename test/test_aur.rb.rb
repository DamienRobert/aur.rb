require 'helper'
require 'aur.rb'

class TestAur.rb < Minitest::Test

  def test_version
    version = Aur.rb.const_get('VERSION')

    assert(!version.empty?, 'should have a VERSION constant')
  end

end
