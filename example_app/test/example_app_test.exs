defmodule ExampleAppTest do
  use ExUnit.Case
  doctest ExampleApp

  test "greets the world" do
    assert ExampleApp.hello() == :world
  end
end
