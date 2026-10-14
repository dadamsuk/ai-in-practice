defmodule AiInPractice.Assessment.PerspectiveTest do
  use ExUnit.Case, async: true

  alias AiInPractice.Assessment.Perspective

  describe ":you, the person's own report" do
    test "speaking to the person passes, and other people may be they" do
      assert Perspective.keeps?("You use AI daily. Your team follows.", :you)
      assert Perspective.keeps?("Your team follows your lead, and they ask you first.", :you)
      assert Perspective.keeps?("Ask the person who owns the process.", :you)
    end

    test "talking about the person fails" do
      refute Perspective.keeps?("They use AI daily.", :you)
      refute Perspective.keeps?("You draft with it. Their checking is thin.", :you)
      refute Perspective.keeps?("First line\nThey measure it.", :you)
      refute Perspective.keeps?("Evidence from this person was thin.", :you)
      refute Perspective.keeps?("The candidate gave one example.", :you)
    end
  end

  describe ":they, the assessor report" do
    test "talking about the person passes" do
      assert Perspective.keeps?("They use AI daily. This person checks every figure.", :they)
      assert Perspective.keeps?("Their youth programme and a bayou depot.", :they)
    end

    test "speaking to the person fails, whatever the case" do
      refute Perspective.keeps?("Your profile is uneven.", :they)
      refute Perspective.keeps?("They check. YOU should too.", :they)
      refute Perspective.keeps?("Ask yourself why.", :they)
    end
  end

  test "the person's own words in quotation marks are skipped" do
    assert Perspective.keeps?(~s(They said "you have to check it" and do.), :they)
    assert Perspective.keeps?("They said “your numbers first” and mean it.", :they)
    assert Perspective.keeps?(~s(You said "They never check it."), :you)
    refute Perspective.keeps?(~s(They said "check it", and your view differs.), :they)
  end

  test "anything that is not text has nothing to break" do
    assert Perspective.keeps?(nil, :they)
    assert Perspective.keeps?(42, :you)
  end
end
