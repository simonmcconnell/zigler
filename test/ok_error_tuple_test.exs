defmodule ZiglerTest.OkErrorTupleTest do
  # tests if the ok/error tuple constructors work

  use ExUnit.Case, async: true
  use Zigler, app: :zigler

  ~Z"""
  /// nif: ok_int/1
  fn ok_int(env: beam.env, val: i64) beam.term {
    return beam.make_ok_tuple(i64, env, val);
  }

  /// nif: ok_atom/1
  fn ok_atom(env: beam.env, str: []u8) beam.term {
    return beam.make_ok_tuple_atom(env, str);
  }

  /// nif: error_int/1
  fn error_int(env: beam.env, val: i64) beam.term {
    return beam.make_error_tuple(i64, env, val);
  }

  /// nif: error_atom/1
  fn error_atom(env: beam.env, str: []u8) beam.term {
    return beam.make_error_tuple_atom(env, str);
  }
  """

  describe "making special tuples works" do
    test "for a numeric ok tuple" do
      assert {:ok, 47} == ok_int(47)
    end

    test "for an atom ok tuple" do
      assert {:ok, :foo} == ok_atom("foo")
    end

    test "for a numeric error tuple" do
      assert {:error, 47} == error_int(47)
    end

    test "for an atom error tuple" do
      assert {:error, :foo} == error_atom("foo")
    end
  end
end
