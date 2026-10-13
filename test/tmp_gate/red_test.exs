defmodule AiInPractice.CdGateProofTest do
  use ExUnit.Case, async: true
  test "deliberately red, to show cd.yml does not publish" do
    assert 1 == 2
  end
end
