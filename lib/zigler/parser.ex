defmodule Zigler.Parser do
  @moduledoc false

  # all functions that parse zig code

  defstruct [:local, :file, global: []]

  import NimbleParsec

  alias Zigler.Nif
  alias Zigler.Zig

  alias Zigler.Parser.Function

  @alphanumeric [?a..?z, ?A..?Z, ?0..?9, ?_]
  @number [?0..?9]

  #############################################################################
  ## nimble_parsec routines

  whitespace = ascii_string([?\s, ?\n], min: 1)
  blankspace = ignore(ascii_string([?\s], min: 1))
  # note that tabs are forbidden by zig.

  identifier =
    ascii_char([?a..?z, ?A..?Z, ?_])
    |> optional(ascii_string(@alphanumeric, min: 1))
    |> reduce({IO, :iodata_to_binary, []})

  namespaced_identifier =
    identifier
    |> repeat(concat(string("."), identifier))
    |> reduce({IO, :iodata_to_binary, []})

  number = ascii_string(@number, min: 1)

  error_decorator = string("!")
  pointer_decorator =
    optional(string("?") |> ignore(optional(whitespace)))
    |> string("*")

  # TODO: sentinel terminated arrays
  array_decorator = string("[")
    |> ignore(optional(whitespace))
    |> optional(string("*c") |> optional(whitespace))
    |> string("]")

  decorator = choice([
    pointer_decorator,
    array_decorator
  ])

  type =
    optional(error_decorator |> ignore(optional(whitespace)))
    |> repeat(decorator |> ignore(optional(whitespace)))
    |> concat(namespaced_identifier)
    |> reduce({IO, :iodata_to_binary, []})

  #############################################################################
  ## INITIALIZATION
  ##
  ## used to initialize nimble_parsec with a struct instead of a generic map.
  ## should be prepended to most things which are turned into parsecs.  You
  ## can also pass information into a parsec function to preseed the context.

  initialize = post_traverse(empty(), :initializer)

  defp initializer(_, _, context, _, _), do: {[], struct(__MODULE__, context)}

  # test harness

  if Mix.env == :test do
    defparsec :parser_initializer, initialize
  end

  #############################################################################
  ## DOCSTRING PARSING
  ##
  ## certain zigler parameters are encoded in zig's /// docstrings.
  ## this includes definitions for nifs and destructors for resources.

  @nif_options Enum.map(~w(long dirty_io dirty_cpu), &string/1)

  docstring_line =
    optional(blankspace)
    |> ignore(string("///"))
    |> optional(blankspace)
    |> lookahead_not(string("nif:"))
    |> optional(utf8_string([not: ?\n], min: 1))
    |> ignore(string("\n"))
    |> post_traverse(:register_docstring_line)

  nif_options = repeat(blankspace |> choice(@nif_options))

  # nif declarations take the form:
  # /// nif: <nif_name>/<arity> [nif_options]
  # where nif_options can be "long", "dirty_io", or "dirty_cpu"
  nif_declaration =
    optional(blankspace)
    |> ignore(string("///"))
    |> optional(blankspace)
    |> ignore(string("nif:"))
    |> concat(blankspace)
    |> concat(identifier)
    |> ignore(string("/"))
    |> concat(number)
    |> optional(nif_options)
    |> optional(blankspace)
    |> ignore(string("\n"))
    |> post_traverse(:register_nif_declaration)

  docstring =
    choice([
      times(docstring_line, min: 1)
      |> optional(nif_declaration),
      nif_declaration
    ])

  # test harness

  if Mix.env == :test do
    defparsec :parse_docstring_line,  concat(initialize, docstring_line)
    defparsec :parse_nif_declaration, concat(initialize, nif_declaration)
    defparsec :parse_docstring,       concat(initialize, docstring)
  end

  # registrations

  # empty docstring line.
  defp register_docstring_line(_rest, [], context = %{local: {:doc, doc}}, _, _) do
    {[], %{context | local: {:doc, [doc, ?\n]}}}
  end
  defp register_docstring_line(_rest, [], context = %{local: nil}, _, _) do
    {[], %{context | local: nil}}
  end
  defp register_docstring_line(_rest, [content], context = %{local: {:doc, doc}}, _, _) do
    {[], %{context | local: {:doc, [doc, ?\n | String.trim(content)]}}}
  end
  defp register_docstring_line(_rest, [content], context = %{local: nil}, _, _) do
    {[], %{context | local: {:doc, String.trim(content)}}}
  end
  defp register_docstring_line(_rest, [_content], context, {line, _}, _) do
    raise CompileError,
      file: context.file,
      line: line,
      description: "docstring found in an inappropriate context"
  end

  # register_nif_declaration/5: trampolines into register_nif_declaration/3
  defp register_nif_declaration(_rest, content, context, _, _) do
    register_nif_declaration(content, context, [])
  end
  # register_nif_declaration/3
  defp register_nif_declaration(content, context = %{local: {:doc, doc}}, opts) do
    register_nif_declaration(content, %{context | local: nil}, opts ++ [doc: doc])
  end
  defp register_nif_declaration(["long" | rest], context, opts) do
    register_nif_declaration(rest, context, opts ++ [long: true])
  end
  defp register_nif_declaration(["dirty_io" | rest], context, opts) do
    register_nif_declaration(rest, context, opts ++ [dirty: :io])
  end
  defp register_nif_declaration(["dirty_cpu" | rest], context, opts) do
    register_nif_declaration(rest, context, opts ++ [dirty: :cpu])
  end
  defp register_nif_declaration([arity, function], context, opts) do
    local = struct(Function,
      name:  String.to_atom(function),
      arity: String.to_integer(arity),
      doc:   opts[:doc],
      opts:  Keyword.take(opts, [:long, :dirty]))
    {[], %{context | local: local}}
  end

  #############################################################################
  ## FUNCTION HEADER PARSING

  parameter =
    ignore(
      identifier
      |> optional(whitespace)
      |> string(":")
      |> optional(whitespace))
    |> concat(type)

  parameter_list =
    ignore(optional(whitespace))
    |> optional(parameter)
    |> repeat(
      ignore(
        optional(whitespace)
        |> string(",")
        |> optional(whitespace))
      |> concat(parameter))

  function_header =
    ignore(
      optional(blankspace)
      |> string("fn")
      |> concat(whitespace))
    |> concat(identifier)
    |> post_traverse(:validate_nif_declaration)
    |> ignore(optional(whitespace) |> string("("))
    |> concat(parameter_list)
    |> ignore(string(")") |> optional(whitespace))
    |> post_traverse(:validate_arity)
    |> post_traverse(:validate_params)
    |> concat(type)
    |> post_traverse(:validate_retval)
    |> ignore(
      repeat(ascii_char(not: ?\n))
      |> string("\n"))
    |> post_traverse(:register_function_header)

  # test harness

  if Mix.env == :test do
    defparsec :parse_parameter, concat(initialize, parameter)
    defparsec :parse_parameter_list, concat(initialize, parameter_list)
    defparsec :parse_function_header, concat(initialize, function_header)
  end

  # validations

  defp validate_nif_declaration(_rest, [nif_name], context = %{local: %Function{name: name}}, {line, _}, _) do
    unless nif_name == Atom.to_string(name) do
      raise CompileError,
        file: context.file,
        line: line,
        description: "nif declaration name #{name} doesn't match function name #{nif_name}"
    end
    {[], context}
  end
  defp validate_nif_declaration(_, _, context, _, _), do: {[], context}

  @beam_envs ["beam.env", "?*e.ErlNifEnv"]

  defp validate_arity(_rest, params, context = %{local: %Function{arity: arity}}, {line, _}, _) do
    {params, validate_arity(Enum.reverse(params), context, line)}
  end
  defp validate_arity(_rest, _, context, _, _), do: {[], context}

  defp validate_arity([env | rest], context, line) when env in @beam_envs do
    validate_arity(rest, context, line)
  end
  defp validate_arity(rest, context = %{local: %{arity: arity}}, line) when length(rest) != arity do
    raise CompileError,
      file: context.file,
      line: line,
      description: "nif declaration arity (#{arity}) doesn't match the expected function arity #{length(rest)}"
  end
  defp validate_arity(_, context, _), do: context

  @valid_params ["i64", "f64"]

  # validate_params/5 : trampolines to validate_params/3
  # ignore parameter validation if we're not in a segment specified by a nif.
  defp validate_params(_rest, content, context = %{local: %Function{}}, {line, _}, _) do
    validate_params(content, context, line)
    {content, context} # since it's a validator, ignore the result of validate_params/3
  end
  defp validate_params(_, content, context, _, _), do: {content, context}
  # validate_params/2 : raises if an invalid parameter type is sent to to the function
  defp validate_params([], _context, _line), do: :ok
  defp validate_params([params | rest], context, line) when params in @valid_params do
    validate_params(rest, context, line)
  end
  defp validate_params([invalid_type | _], context, line) do
    raise CompileError,
      file: context.file,
      line: line,
      description: "nif function #{context.local.name} demands an invalid parameter type #{invalid_type}"
  end

  @valid_retvals ["i64"]

  defp validate_retval(_rest, content = [retval | _], context = %{local: %Function{}}, _, _)
    when retval in @valid_retvals do
    {content, context}
  end
  defp validate_retval(_rest, content = [retval | _], context = %{local: %Function{}}, {line, _}, _) do
    raise CompileError,
      file: context.file,
      line: line,
      description: "nif function #{context.local.name} returns an invalid type #{retval}"
    {content, context}
  end
  defp validate_retval(_, _, context, _, _), do: {[], context}

  # registrations

  defp register_function_header(_, [retval | params], context = %{local: function = %Function{}}, _, _) do
    final_function = %{function | retval: retval, params: Enum.reverse(params)}
    {[], %{context | global: [final_function | context.global], local: nil}}
  end
  defp register_function_header(_, _, context, _, _), do: {[], context}

  #############################################################################
  ## FULL PARSER

  ignored_line =
    optional(utf8_string([not: ?\n], min: 1))
    |> string("\n")
    |> post_traverse(:clear)

  zig_block =
    initialize
    |> repeat(choice([
      docstring,
      function_header,
      ignored_line,
    ]))

  defparsec :parse_zig_block, zig_block

  defp clear(rest, content, context, _, _) do
    {[], context}
  end

  #############################################################################
  ## API

  def parse(code, previous_context \\ %__MODULE__{}) do
    case parse_zig_block(code, context: Map.from_struct(previous_context)) do
      {:ok, [], "", parser, _, _} -> parser
      {:error, msg, _context, {line, _}, _} ->
        raise CompileError,
          file: previous_context.file,
          line: line,
          description: msg
      err ->
        raise CompileError,
          file: previous_context.file,
          line: 1,
          description: "unknown parsing error #{inspect err}"
    end
  end

  #line =
  #  utf8_string([not: ?\n], min: 1)
  #  |> string("\n")
  #  |> post_traverse(:clear_data)
  #  |> reduce({Enum, :join, []})
#
  #empty_line = string("\n")
#
  #by_line =
  #  repeat(choice([
  #    docstring,
  #    function_header,
  #    line,
  #    empty_line
  #  ]))
#
  #defparsec :zig_by_line, by_line
#
  #@spec parse(String.t, Path.t, non_neg_integer) :: %{code: iodata, nifs: [Zigler.Nif.t]}
  #def parse(code, file, line) do
  #  # prepend a comment saving the file and line metadata.
  #  marker_comment = "// #{file} line: #{line}\n"
#
  #  {:ok, new_code, _, _, _, _} = zig_by_line(code, line: line, context: %{file: file})
#
  #  Enum.reduce(new_code, %{code: marker_comment, nifs: [], imports: []}, fn
  #    res = %Zigler.Nif{}, acc = %{nifs: nifs} ->
  #      %{acc | nifs: [res | nifs]}
  #    any, acc = %{code: code} ->
  #      %{acc | code: [code, any]}
  #  end)
  #end
end
