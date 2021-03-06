%% @doc Rebar3 Pretty Printing of abstract Erlang syntax trees,
%% based on original erl_prettypr.
%%
%% It was taken verbatim from erl_prettypr
%% and it was modified to meet our specific needs.
%%
%% This module is a front end to the pretty-printing library module
%% `prettypr', for text formatting of abstract syntax trees defined by
%% the module `erl_syntax'.
-module(rebar3_prettypr).

-export([format/3]).

-import(prettypr,
        [text/1, nest/2, above/2, beside/2, sep/1, par/1, par/2, floating/3, floating/1,
         break/1, follow/2, follow/3, empty/0]).

-import(erl_parse,
        [preop_prec/1, inop_prec/1, func_prec/0, max_prec/0, type_inop_prec/1,
         type_preop_prec/1]).

-define(PADDING, 2).

-define(PAPER, 80).

-define(RIBBON, 56).

-define(BREAK_INDENT, 4).

-define(SUB_INDENT, 2).

-define(NOUSER, undefined).

-type clause_t() :: case_expr | fun_expr | if_expr | receive_expr | try_expr |
                    {function, prettypr:document()} | spec.

-record(ctxt,
        {prec = 0  :: integer(), sub_indent = ?SUB_INDENT  :: non_neg_integer(),
         break_indent = ?BREAK_INDENT  :: non_neg_integer(),
         clause = undefined  :: clause_t() | undefined, paper = ?PAPER  :: integer(),
         ribbon = ?RIBBON  :: integer(), user = ?NOUSER  :: term(),
         inline_items = true  :: boolean(), inline_expressions = true  :: boolean(),
         empty_lines = []  :: [pos_integer()],
         newline_after_attributes = true  :: boolean(),
         encoding = epp:default_encoding()  :: epp:source_encoding()}).

set_prec(Ctxt, Prec) ->
    Ctxt#ctxt{prec = Prec}.    % used internally

reset_prec(Ctxt) ->
    set_prec(Ctxt, 0).    % used internally

%% =====================================================================
%% @doc Prettyprint-formats an abstract Erlang syntax tree as text. For
%% example, if you have a `.beam' file that has been compiled with
%% `debug_info', the following should print the source code for the
%% module (as it looks in the debug info representation):
%% ```{ok,{_,[{abstract_code,{_,AC}}]}} =
%%            beam_lib:chunks("myfile.beam",[abstract_code]),
%%    io:put_chars(rebar3_prettypr:format(erl_syntax:form_list(AC), [], []))
%% '''
%%
%% Available options:
%% <dl>
%%   <dt>{paper, integer()}</dt>
%%       <dd>Specifies the preferred maximum number of characters on any
%%       line, including indentation. The default value is 80.</dd>
%%
%%   <dt>{ribbon, integer()}</dt>
%%       <dd>Specifies the preferred maximum number of characters on any
%%       line, not counting indentation. The default value is 65.</dd>
%%
%%   <dt>{break_indent, integer()}</dt>
%%       <dd>Specifies the number of spaces to use for breaking indentation.
%%       The default value is 4.</dd>
%%
%%   <dt>{sub_indent, integer()}</dt>
%%       <dd>Specifies the number of spaces to use for breaking indentation.
%%       The default value is 2.</dd>
%%
%%   <dt>{inline_items, boolean()}</dt>
%%       <dd>Specifies the desired behavior when using multiple lines for a
%%       multi-item structure (i.e. tuple, list, map, etc.).
%%       When this flag is on, the formatter will try to fit as many items
%%       in each line as permitted by 'paper' and 'ribbon'.
%%       Otherwise, the formatter will place each item in its own line.
%%       The default value is true.</dd>
%%
%%   <dt>{inline_expressions, boolean()}</dt>
%%       <dd>Specifies wether multiple sequential expressions within the
%%       same clause can be placed in the same line (if paper/ribbon permits).
%%       The default value is true.</dd>
%%
%%   <dt>{encoding, epp:source_encoding()}</dt>
%%       <dd>Specifies the encoding of the generated file.</dd>
%%
%%   <dt>{newline_after_attributes, boolean()}</dt>
%%       <dd>Specifies if attributes must be separated from the code below
%%       them by an empty line.
%%       The default value is true.</dd>
%% </dl>
%%
%% @see erl_syntax
%% @see format/1
%% @see layout/2
-spec format(erl_syntax:syntaxTree(), [pos_integer()], [term()]) -> string().

format(Node, EmptyLines, Options) ->
    W = proplists:get_value(paper, Options, ?PAPER),
    L = proplists:get_value(ribbon, Options, ?RIBBON),
    prettypr:format(layout(Node, EmptyLines, Options), W, L).

%% =====================================================================
%% @doc Creates an abstract document layout for a syntax tree. The
%% result represents a set of possible layouts (cf. module `prettypr').
%% For information on the options, see {@link format/2}; note, however,
%% that the `paper' and `ribbon' options are ignored by this function.
%%
%% This function provides a low-level interface to the pretty printer,
%% returning a flexible representation of possible layouts, independent
%% of the paper width eventually to be used for formatting. This can be
%% included as part of another document and/or further processed
%% directly by the functions in the `prettypr' module (see `format/2'
%% for details).
%%
%% @see prettypr
%% @see format/2
-spec layout(erl_syntax:syntaxTree(), [pos_integer()],
             [term()]) -> prettypr:document().

layout(Node, EmptyLines, Options) ->
    lay(Node,
        #ctxt{paper = proplists:get_value(paper, Options, ?PAPER),
              ribbon = proplists:get_value(ribbon, Options, ?RIBBON),
              break_indent = proplists:get_value(break_indent, Options, ?BREAK_INDENT),
              sub_indent = proplists:get_value(sub_indent, Options, ?SUB_INDENT),
              inline_expressions = proplists:get_value(inline_expressions, Options, true),
              inline_items = proplists:get_value(inline_items, Options, true),
              newline_after_attributes =
                  proplists:get_value(newline_after_attributes, Options, true),
              empty_lines = EmptyLines,
              encoding = proplists:get_value(encoding, Options, epp:default_encoding())}).

lay(Node, Ctxt) ->
    case erl_syntax:has_comments(Node) of
      true ->
          D1 = lay_no_comments(Node, Ctxt),
          D2 = lay_postcomments(erl_syntax:get_postcomments(Node), D1),
          lay_precomments(erl_syntax:get_precomments(Node), D2);
      false -> lay_no_comments(Node, Ctxt)
    end.

%% For pre-comments, all padding is ignored.
lay_precomments([], D) -> D;
lay_precomments(Cs, D) ->
    above(floating(break(stack_comments(Cs, false)), -1, -1), D).

%% For postcomments, individual padding is added.
lay_postcomments([], D) -> D;
lay_postcomments(Cs, D) ->
    beside(D, floating(break(stack_comments(Cs, true)), 1, 0)).

%% Format (including padding, if `Pad' is `true', otherwise not)
%% and stack the listed comments above each other.
stack_comments([C | Cs], Pad) ->
    D = stack_comment_lines(erl_syntax:comment_text(C)),
    D1 = case Pad of
           true ->
               P = case erl_syntax:comment_padding(C) of
                     none -> ?PADDING;
                     P1 -> P1
                   end,
               beside(text(spaces(P)), D);
           false -> D
         end,
    case Cs of
      [] ->
          D1; % done
      _ -> above(D1, stack_comments(Cs, Pad))
    end.

%% Stack lines of text above each other and prefix each string in
%% the list with a single `%' character.
stack_comment_lines([S | Ss]) ->
    D = text(add_comment_prefix(S)),
    case Ss of
      [] -> D;
      _ -> above(D, stack_comment_lines(Ss))
    end;
stack_comment_lines([]) -> empty().

add_comment_prefix(S) -> [$% | S].

%% This part ignores annotations and comments:
lay_no_comments(Node, Ctxt) ->
    case erl_syntax:type(Node) of
      %% We list literals and other common cases first.
      variable -> text(erl_syntax:variable_literal(Node));
      atom -> text(erl_syntax:atom_literal(Node, Ctxt#ctxt.encoding));
      integer -> text(tidy_integer(Node));
      float -> text(tidy_float(Node));
      char -> text(erl_syntax:char_literal(Node, Ctxt#ctxt.encoding));
      string -> lay_string(erl_syntax:string_literal(Node, Ctxt#ctxt.encoding), Ctxt);
      nil -> text("[]");
      tuple ->
          Es = lay_items(erl_syntax:tuple_elements(Node), reset_prec(Ctxt), fun lay/2),
          beside(lay_text_float("{"), beside(Es, lay_text_float("}")));
      list ->
          Ctxt1 = reset_prec(Ctxt),
          Node1 = erl_syntax:compact_list(Node),
          D1 = lay_items(erl_syntax:list_prefix(Node1), Ctxt1, fun lay/2),
          D = case erl_syntax:list_suffix(Node1) of
                none -> beside(D1, lay_text_float("]"));
                S ->
                    follow(D1,
                           beside(lay_text_float("| "), beside(lay(S, Ctxt1), lay_text_float("]"))))
              end,
          beside(lay_text_float("["), D);
      operator -> lay_text_float(erl_syntax:operator_literal(Node));
      infix_expr ->
          Operator = erl_syntax:infix_expr_operator(Node),
          {PrecL, Prec, PrecR} = case erl_syntax:type(Operator) of
                                   operator -> inop_prec(erl_syntax:operator_name(Operator));
                                   _ -> {0, 0, 0}
                                 end,
          D1 = lay(erl_syntax:infix_expr_left(Node), set_prec(Ctxt, PrecL)),
          D2 = lay(Operator, reset_prec(Ctxt)),
          D3 = lay(erl_syntax:infix_expr_right(Node), set_prec(Ctxt, PrecR)),
          D4 = par([D1, D2, D3], Ctxt#ctxt.sub_indent),
          maybe_parentheses(D4, Prec, Ctxt);
      prefix_expr ->
          Operator = erl_syntax:prefix_expr_operator(Node),
          {{Prec, PrecR}, Name} = case erl_syntax:type(Operator) of
                                    operator ->
                                        N = erl_syntax:operator_name(Operator), {preop_prec(N), N};
                                    _ -> {{0, 0}, any}
                                  end,
          D1 = lay(Operator, reset_prec(Ctxt)),
          D2 = lay(erl_syntax:prefix_expr_argument(Node), set_prec(Ctxt, PrecR)),
          D3 = case Name of
                 '+' -> beside(D1, D2);
                 '-' -> beside(D1, D2);
                 _ -> par([D1, D2], Ctxt#ctxt.sub_indent)
               end,
          maybe_parentheses(D3, Prec, Ctxt);
      application ->
          lay_application(erl_syntax:application_operator(Node),
                          erl_syntax:application_arguments(Node), Ctxt);
      match_expr ->
          {PrecL, Prec, PrecR} = inop_prec('='),
          D1 = lay(erl_syntax:match_expr_pattern(Node), set_prec(Ctxt, PrecL)),
          D2 = lay(erl_syntax:match_expr_body(Node), set_prec(Ctxt, PrecR)),
          D3 = follow(beside(D1, lay_text_float(" =")), D2, Ctxt#ctxt.break_indent),
          maybe_parentheses(D3, Prec, Ctxt);
      underscore -> text("_");
      clause ->
          %% The style used for a clause depends on its context
          Ctxt1 = (reset_prec(Ctxt))#ctxt{clause = undefined},
          D1 = lay_items(erl_syntax:clause_patterns(Node), Ctxt1, fun lay/2),
          D2 = case erl_syntax:clause_guard(Node) of
                 none -> none;
                 G -> lay(G, Ctxt1)
               end,
          D3 = lay_clause_expressions(erl_syntax:clause_body(Node), Ctxt1, fun lay/2),
          case Ctxt#ctxt.clause of
            fun_expr -> make_fun_clause(D1, D2, D3, Ctxt);
            {function, N} -> make_fun_clause(N, D1, D2, D3, Ctxt);
            if_expr -> make_if_clause(D2, D3, Ctxt);
            case_expr -> make_case_clause(D1, D2, D3, Ctxt);
            receive_expr -> make_case_clause(D1, D2, D3, Ctxt);
            try_expr -> make_case_clause(D1, D2, D3, Ctxt);
            undefined ->
                %% If a clause is formatted out of context, we
                %% use a "fun-expression" clause style.
                make_fun_clause(D1, D2, D3, Ctxt)
          end;
      function ->
          %% Comments on the name itself will be repeated for each
          %% clause, but that seems to be the best way to handle it.
          Ctxt1 = reset_prec(Ctxt),
          D1 = lay(erl_syntax:function_name(Node), Ctxt1),
          D2 = lay_clauses(erl_syntax:function_clauses(Node), {function, D1}, Ctxt1),
          beside(D2, lay_text_float("."));
      case_expr ->
          Ctxt1 = reset_prec(Ctxt),
          D1 = lay(erl_syntax:case_expr_argument(Node), Ctxt1),
          D2 = lay_clauses(erl_syntax:case_expr_clauses(Node), case_expr, Ctxt1),
          sep([par([follow(text("case"), D1, Ctxt1#ctxt.sub_indent), text("of")],
                   Ctxt1#ctxt.break_indent),
               nest(Ctxt1#ctxt.sub_indent, D2), text("end")]);
      if_expr ->
          Ctxt1 = reset_prec(Ctxt),
          D = lay_clauses(erl_syntax:if_expr_clauses(Node), if_expr, Ctxt1),
          sep([follow(text("if"), D, Ctxt1#ctxt.sub_indent), text("end")]);
      fun_expr ->
          Ctxt1 = reset_prec(Ctxt),
          Clauses = lay_clauses(erl_syntax:fun_expr_clauses(Node), fun_expr, Ctxt1),
          lay_fun_sep(Clauses, Ctxt1);
      named_fun_expr ->
          Ctxt1 = reset_prec(Ctxt),
          D1 = lay(erl_syntax:named_fun_expr_name(Node), Ctxt1),
          Clauses = lay_clauses(erl_syntax:named_fun_expr_clauses(Node), {function, D1},
                                Ctxt1),
          lay_fun_sep(Clauses, Ctxt1);
      module_qualifier ->
          {PrecL, _Prec, PrecR} = inop_prec(':'),
          D1 = lay(erl_syntax:module_qualifier_argument(Node), set_prec(Ctxt, PrecL)),
          D2 = lay(erl_syntax:module_qualifier_body(Node), set_prec(Ctxt, PrecR)),
          beside(D1, beside(text(":"), D2));
      %%
      %% The rest is in alphabetical order (except map and types)
      %%
      arity_qualifier ->
          Ctxt1 = reset_prec(Ctxt),
          D1 = lay(erl_syntax:arity_qualifier_body(Node), Ctxt1),
          D2 = lay(erl_syntax:arity_qualifier_argument(Node), Ctxt1),
          beside(D1, beside(text("/"), D2));
      attribute ->
          %% The attribute name and arguments are formatted similar to
          %% a function call, but prefixed with a "-" and followed by
          %% a period. If the arguments is `none', we only output the
          %% attribute name, without following parentheses.
          Ctxt1 = reset_prec(Ctxt),
          Args = erl_syntax:attribute_arguments(Node),
          N = case erl_syntax:attribute_name(Node) of
                {atom, _, 'if'} -> erl_syntax:variable('if');
                N0 -> N0
              end,
          D = case attribute_name(Node) of
                Tag when Tag =:= spec; Tag =:= callback ->
                    [SpecTuple] = Args,
                    [FuncName, FuncTypes] = erl_syntax:tuple_elements(SpecTuple),
                    Name = get_func_node(FuncName),
                    Types = dodge_macros(FuncTypes),
                    D1 = lay_clauses(erl_syntax:concrete(Types), spec, Ctxt1),
                    beside(follow(lay(N, Ctxt1), lay(Name, Ctxt1), Ctxt1#ctxt.break_indent), D1);
                Tag when Tag =:= type; Tag =:= opaque ->
                    [TypeTuple] = Args,
                    [Name, Type0, Elements] = erl_syntax:tuple_elements(TypeTuple),
                    TypeName = dodge_macros(Name),
                    Type = dodge_macros(Type0),
                    As0 = dodge_macros(Elements),
                    As = erl_syntax:concrete(As0),
                    D1 = lay_application(TypeName, As, Ctxt1),
                    D2 = lay(erl_syntax:concrete(Type), Ctxt1),
                    beside(follow(lay(N, Ctxt1), beside(D1, lay_text_float(" :: ")),
                                  Ctxt1#ctxt.break_indent),
                           D2);
                Tag when Tag =:= export_type; Tag =:= optional_callbacks ->
                    [FuncNs] = Args,
                    FuncNames = erl_syntax:concrete(dodge_macros(FuncNs)),
                    As = unfold_function_names(FuncNames),
                    beside(lay(N, Ctxt1),
                           beside(text("("), beside(lay(As, Ctxt1), lay_text_float(")"))));
                _ when Args =:= none -> lay(N, Ctxt1);
                _ -> lay_application(N, Args, Ctxt1)
              end,
          beside(lay_text_float("-"), beside(D, lay_text_float(".")));
      binary ->
          Ctxt1 = reset_prec(Ctxt),
          Es = lay_items(erl_syntax:binary_fields(Node), Ctxt1, fun lay/2),
          beside(lay_text_float("<<"), beside(Es, lay_text_float(">>")));
      binary_field ->
          Ctxt1 = set_prec(Ctxt, max_prec()),
          D1 = lay(erl_syntax:binary_field_body(Node), Ctxt1),
          D2 = case erl_syntax:binary_field_types(Node) of
                 [] -> empty();
                 Ts -> beside(lay_text_float("/"), lay_bit_types(Ts, Ctxt1))
               end,
          beside(D1, D2);
      block_expr ->
          Ctxt1 = reset_prec(Ctxt),
          Es = lay_clause_expressions(erl_syntax:block_expr_body(Node), Ctxt1, fun lay/2),
          sep([text("begin"), nest(Ctxt1#ctxt.sub_indent, Es), text("end")]);
      catch_expr ->
          {Prec, PrecR} = preop_prec('catch'),
          D = lay(erl_syntax:catch_expr_body(Node), set_prec(Ctxt, PrecR)),
          D1 = follow(text("catch"), D, Ctxt#ctxt.sub_indent),
          maybe_parentheses(D1, Prec, Ctxt);
      class_qualifier ->
          Ctxt1 = set_prec(Ctxt, max_prec()),
          D1 = lay(erl_syntax:class_qualifier_argument(Node), Ctxt1),
          D2 = lay(erl_syntax:class_qualifier_body(Node), Ctxt1),
          Stacktrace = erl_syntax:class_qualifier_stacktrace(Node),
          case erl_syntax:variable_name(Stacktrace) of
            '_' -> beside(D1, beside(text(":"), D2));
            _ ->
                D3 = lay(Stacktrace, Ctxt1),
                beside(D1, beside(beside(text(":"), D2), beside(text(":"), D3)))
          end;
      comment ->
          D = stack_comment_lines(erl_syntax:comment_text(Node)),
          %% Default padding for standalone comments is empty.
          case erl_syntax:comment_padding(Node) of
            none -> floating(break(D));
            P -> floating(break(beside(text(spaces(P)), D)))
          end;
      conjunction ->
          lay_items(erl_syntax:conjunction_body(Node), reset_prec(Ctxt), fun lay/2);
      disjunction ->
          %% For clarity, we don't paragraph-format
          %% disjunctions; only conjunctions (see above).
          sep(seq(erl_syntax:disjunction_body(Node), lay_text_float(";"),
                  reset_prec(Ctxt), fun lay/2));
      error_marker ->
          E = erl_syntax:error_marker_info(Node),
          beside(text("** "), beside(lay_error_info(E, reset_prec(Ctxt)), text(" **")));
      eof_marker -> empty();
      form_list ->
          Es = seq(erl_syntax:form_list_elements(Node), none, reset_prec(Ctxt),
                   fun lay/2),
          AddEmptyLines = empty_lines_to_add(erl_syntax:form_list_elements(Node), Ctxt),
          vertical_sep(lists:zip(Es, AddEmptyLines));
      generator ->
          Ctxt1 = reset_prec(Ctxt),
          D1 = lay(erl_syntax:generator_pattern(Node), Ctxt1),
          D2 = lay(erl_syntax:generator_body(Node), Ctxt1),
          par([D1, beside(text("<- "), D2)], Ctxt1#ctxt.break_indent);
      binary_generator ->
          Ctxt1 = reset_prec(Ctxt),
          D1 = lay(erl_syntax:binary_generator_pattern(Node), Ctxt1),
          D2 = lay(erl_syntax:binary_generator_body(Node), Ctxt1),
          par([D1, beside(text("<= "), D2)], Ctxt1#ctxt.break_indent);
      implicit_fun ->
          D = lay(erl_syntax:implicit_fun_name(Node), reset_prec(Ctxt)),
          beside(lay_text_float("fun "), D);
      list_comp ->
          Ctxt1 = reset_prec(Ctxt),
          D1 = lay(erl_syntax:list_comp_template(Node), Ctxt1),
          D2 = lay_items(erl_syntax:list_comp_body(Node), Ctxt1, fun lay/2),
          beside(lay_text_float("["),
                 par([D1, beside(lay_text_float("|| "), beside(D2, lay_text_float("]")))]));
      binary_comp ->
          Ctxt1 = reset_prec(Ctxt),
          D1 = lay(erl_syntax:binary_comp_template(Node), Ctxt1),
          D2 = lay_items(erl_syntax:binary_comp_body(Node), Ctxt1, fun lay/2),
          beside(lay_text_float("<< "),
                 par([D1, beside(lay_text_float(" || "), beside(D2, lay_text_float(" >>")))]));
      macro ->
          %% This is formatted similar to a normal function call, but
          %% prefixed with a "?".
          Ctxt1 = reset_prec(Ctxt),
          N = erl_syntax:macro_name(Node),
          D = case erl_syntax:macro_arguments(Node) of
                none -> lay(N, Ctxt1);
                Args -> lay_application(N, Args, Ctxt1)
              end,
          D1 = beside(lay_text_float("?"), D),
          maybe_parentheses(D1, 0, Ctxt1);
      parentheses ->
          D = lay(erl_syntax:parentheses_body(Node), reset_prec(Ctxt)),
          lay_parentheses(D, Ctxt);
      receive_expr ->
          Ctxt1 = reset_prec(Ctxt),
          D1 = lay_clauses(erl_syntax:receive_expr_clauses(Node), receive_expr, Ctxt1),
          D2 = case erl_syntax:receive_expr_timeout(Node) of
                 none -> D1;
                 T ->
                     D3 = lay(T, Ctxt1),
                     D4 = lay_clause_expressions(erl_syntax:receive_expr_action(Node), Ctxt1,
                                                 fun lay/2),
                     sep([D1,
                          follow(lay_text_float("after"), append_clause_body(D4, D3, Ctxt1),
                                 Ctxt1#ctxt.sub_indent)])
               end,
          sep([text("receive"), nest(Ctxt1#ctxt.sub_indent, D2), text("end")]);
      record_access ->
          {PrecL, Prec, PrecR} = inop_prec('#'),
          D1 = lay(erl_syntax:record_access_argument(Node), set_prec(Ctxt, PrecL)),
          D2 = beside(lay_text_float("."),
                      lay(erl_syntax:record_access_field(Node), set_prec(Ctxt, PrecR))),
          T = erl_syntax:record_access_type(Node),
          D3 = beside(beside(lay_text_float("#"), lay(T, reset_prec(Ctxt))), D2),
          maybe_parentheses(beside(D1, D3), Prec, Ctxt);
      record_expr ->
          Ctxt1 = reset_prec(Ctxt),
          D1 = lay(erl_syntax:record_expr_type(Node), Ctxt1),
          D2 = lay_items(erl_syntax:record_expr_fields(Node), Ctxt1, fun lay/2),
          D3 = beside(beside(lay_text_float("#"), D1),
                      beside(text("{"), beside(D2, lay_text_float("}")))),
          Arg = erl_syntax:record_expr_argument(Node),
          lay_expr_argument(Arg, D3, Ctxt);
      record_field ->
          Ctxt1 = reset_prec(Ctxt),
          D1 = lay(erl_syntax:record_field_name(Node), Ctxt1),
          case erl_syntax:record_field_value(Node) of
            none -> D1;
            V -> par([D1, lay_text_float("="), lay(V, Ctxt1)], Ctxt1#ctxt.break_indent)
          end;
      record_index_expr ->
          {Prec, PrecR} = preop_prec('#'),
          D1 = lay(erl_syntax:record_index_expr_type(Node), reset_prec(Ctxt)),
          D2 = lay(erl_syntax:record_index_expr_field(Node), set_prec(Ctxt, PrecR)),
          D3 = beside(beside(lay_text_float("#"), D1), beside(lay_text_float("."), D2)),
          maybe_parentheses(D3, Prec, Ctxt);
      map_expr ->
          Ctxt1 = reset_prec(Ctxt),
          D1 = lay_items(erl_syntax:map_expr_fields(Node), Ctxt1, fun lay/2),
          D2 = beside(text("#{"), beside(D1, lay_text_float("}"))),
          Arg = erl_syntax:map_expr_argument(Node),
          lay_expr_argument(Arg, D2, Ctxt);
      map_field_assoc ->
          Name = erl_syntax:map_field_assoc_name(Node),
          Value = erl_syntax:map_field_assoc_value(Node),
          lay_type_assoc(Name, Value, Ctxt);
      map_field_exact ->
          Name = erl_syntax:map_field_exact_name(Node),
          Value = erl_syntax:map_field_exact_value(Node),
          lay_type_exact(Name, Value, Ctxt);
      size_qualifier ->
          Ctxt1 = set_prec(Ctxt, max_prec()),
          D1 = lay(erl_syntax:size_qualifier_body(Node), Ctxt1),
          D2 = lay(erl_syntax:size_qualifier_argument(Node), Ctxt1),
          beside(D1, beside(text(":"), D2));
      text -> text(erl_syntax:text_string(Node));
      typed_record_field ->
          {_, Prec, _} = type_inop_prec('::'),
          Ctxt1 = reset_prec(Ctxt),
          D1 = lay(erl_syntax:typed_record_field_body(Node), Ctxt1),
          D2 = lay(erl_syntax:typed_record_field_type(Node), set_prec(Ctxt, Prec)),
          D3 = par([D1, lay_text_float(" ::"), D2], Ctxt1#ctxt.break_indent),
          maybe_parentheses(D3, Prec, Ctxt);
      try_expr ->
          Ctxt1 = reset_prec(Ctxt),
          D1 = lay_clause_expressions(erl_syntax:try_expr_body(Node), Ctxt1, fun lay/2),
          Es0 = [text("end")],
          Es1 = case erl_syntax:try_expr_after(Node) of
                  [] -> Es0;
                  As ->
                      D2 = lay_clause_expressions(As, Ctxt1, fun lay/2),
                      [text("after"), nest(Ctxt1#ctxt.sub_indent, D2) | Es0]
                end,
          Es2 = case erl_syntax:try_expr_handlers(Node) of
                  [] -> Es1;
                  Hs ->
                      D3 = lay_clauses(Hs, try_expr, Ctxt1),
                      [text("catch"), nest(Ctxt1#ctxt.sub_indent, D3) | Es1]
                end,
          Es3 = case erl_syntax:try_expr_clauses(Node) of
                  [] -> Es2;
                  Cs ->
                      D4 = lay_clauses(Cs, try_expr, Ctxt1),
                      [text("of"), nest(Ctxt1#ctxt.sub_indent, D4) | Es2]
                end,
          sep([par([follow(text("try"), D1, Ctxt1#ctxt.sub_indent), hd(Es3)]) | tl(Es3)]);
      warning_marker ->
          E = erl_syntax:warning_marker_info(Node),
          beside(text("%% WARNING: "), lay_error_info(E, reset_prec(Ctxt)));
      %%
      %% Types
      %%
      annotated_type ->
          {_, Prec, _} = type_inop_prec('::'),
          D1 = lay(erl_syntax:annotated_type_name(Node), reset_prec(Ctxt)),
          D2 = lay(erl_syntax:annotated_type_body(Node), set_prec(Ctxt, Prec)),
          D3 = lay_follow_beside_text_float(D1, D2, Ctxt),
          maybe_parentheses(D3, Prec, Ctxt);
      type_application ->
          Name = erl_syntax:type_application_name(Node),
          Arguments = erl_syntax:type_application_arguments(Node),
          %% Prefer shorthand notation.
          case erl_syntax_lib:analyze_type_application(Node) of
            {nil, 0} -> text("[]");
            {list, 1} ->
                [A] = Arguments,
                D1 = lay(A, reset_prec(Ctxt)),
                beside(text("["), beside(D1, text("]")));
            {nonempty_list, 1} ->
                [A] = Arguments,
                D1 = lay(A, reset_prec(Ctxt)),
                beside(text("["), beside(D1, text(", ...]")));
            _ -> lay_application(Name, Arguments, Ctxt)
          end;
      bitstring_type ->
          Ctxt1 = set_prec(Ctxt, max_prec()),
          M = erl_syntax:bitstring_type_m(Node),
          N = erl_syntax:bitstring_type_n(Node),
          D1 = [beside(text("_:"), lay(M, Ctxt1))
                || erl_syntax:type(M) =/= integer orelse erl_syntax:integer_value(M) =/= 0],
          D2 = [beside(text("_:_*"), lay(N, Ctxt1))
                || erl_syntax:type(N) =/= integer orelse erl_syntax:integer_value(N) =/= 0],
          F = fun (D, _) -> D end,
          D = lay_items(D1 ++ D2, Ctxt1, F),
          beside(lay_text_float("<<"), beside(D, lay_text_float(">>")));
      fun_type -> text("fun()");
      constrained_function_type ->
          Ctxt1 = reset_prec(Ctxt),
          D1 = lay(erl_syntax:constrained_function_type_body(Node), Ctxt1),
          Ctxt2 = Ctxt1#ctxt{clause = undefined},
          D2 = lay(erl_syntax:constrained_function_type_argument(Node), Ctxt2),
          beside(D1, beside(lay_text_float(" when "), D2));
      function_type ->
          {Before, After} = case Ctxt#ctxt.clause of
                              spec -> {"", ""};
                              _ -> {"fun(", ")"}
                            end,
          Ctxt1 = (reset_prec(Ctxt))#ctxt{clause = undefined},
          D1 = case erl_syntax:function_type_arguments(Node) of
                 any_arity -> text("(...)");
                 Arguments ->
                     As = lay_items(Arguments, Ctxt1, fun lay/2),
                     beside(text("("), beside(As, lay_text_float(")")))
               end,
          D2 = lay(erl_syntax:function_type_return(Node), Ctxt1),
          beside(lay_text_float(Before),
                 beside(D1, beside(lay_text_float(" -> "), beside(D2, lay_text_float(After)))));
      constraint ->
          Name = erl_syntax:constraint_argument(Node),
          Args = erl_syntax:constraint_body(Node),
          case is_subtype(Name, Args) of
            true ->
                [Var, Type] = Args,
                {PrecL, Prec, PrecR} = type_inop_prec('::'),
                D1 = lay(Var, set_prec(Ctxt, PrecL)),
                D2 = lay(Type, set_prec(Ctxt, PrecR)),
                D3 = lay_follow_beside_text_float(D1, D2, Ctxt),
                maybe_parentheses(D3, Prec, Ctxt);
            false -> lay_application(Name, Args, Ctxt)
          end;
      map_type ->
          case erl_syntax:map_type_fields(Node) of
            any_size -> text("map()");
            Fs ->
                Ctxt1 = reset_prec(Ctxt),
                Es = lay_items(Fs, Ctxt1, fun lay/2),
                D = beside(lay_text_float("#{"), beside(Es, lay_text_float("}"))),
                {Prec, _PrecR} = type_preop_prec('#'),
                maybe_parentheses(D, Prec, Ctxt)
          end;
      map_type_assoc ->
          Name = erl_syntax:map_type_assoc_name(Node),
          Value = erl_syntax:map_type_assoc_value(Node),
          lay_type_assoc(Name, Value, Ctxt);
      map_type_exact ->
          Name = erl_syntax:map_type_exact_name(Node),
          Value = erl_syntax:map_type_exact_value(Node),
          lay_type_exact(Name, Value, Ctxt);
      integer_range_type ->
          {PrecL, Prec, PrecR} = type_inop_prec('..'),
          D1 = lay(erl_syntax:integer_range_type_low(Node), set_prec(Ctxt, PrecL)),
          D2 = lay(erl_syntax:integer_range_type_high(Node), set_prec(Ctxt, PrecR)),
          D3 = beside(D1, beside(text(".."), D2)),
          maybe_parentheses(D3, Prec, Ctxt);
      record_type ->
          {Prec, _PrecR} = type_preop_prec('#'),
          D1 = beside(text("#"),
                      lay(erl_syntax:record_type_name(Node), reset_prec(Ctxt))),
          Es = lay_items(erl_syntax:record_type_fields(Node), reset_prec(Ctxt),
                         fun lay/2),
          D2 = beside(D1, beside(text("{"), beside(Es, lay_text_float("}")))),
          maybe_parentheses(D2, Prec, Ctxt);
      record_type_field ->
          Ctxt1 = reset_prec(Ctxt),
          D1 = lay(erl_syntax:record_type_field_name(Node), Ctxt1),
          D2 = lay(erl_syntax:record_type_field_type(Node), Ctxt1),
          par([D1, lay_text_float("::"), D2], Ctxt1#ctxt.break_indent);
      tuple_type ->
          case erl_syntax:tuple_type_elements(Node) of
            any_size -> text("tuple()");
            Elements ->
                Es = lay_items(Elements, reset_prec(Ctxt), fun lay/2),
                beside(lay_text_float("{"), beside(Es, lay_text_float("}")))
          end;
      type_union ->
          {_, Prec, PrecR} = type_inop_prec('|'),
          Es = lay_items(erl_syntax:type_union_types(Node), lay_text_float(" |"),
                         set_prec(Ctxt, PrecR), fun lay/2),
          maybe_parentheses(Es, Prec, Ctxt);
      user_type_application ->
          lay_application(erl_syntax:user_type_application_name(Node),
                          erl_syntax:user_type_application_arguments(Node), Ctxt)
    end.

attribute_name(Node) ->
    N = erl_syntax:attribute_name(Node),
    try erl_syntax:concrete(N) catch _:_ -> N end.

is_subtype(Name, [Var, _]) ->
    erl_syntax:is_atom(Name, is_subtype) andalso erl_syntax:type(Var) =:= variable;
is_subtype(_, _) -> false.

get_func_node(Node) ->
    case erl_syntax:type(Node) of
      tuple ->
          case erl_syntax:tuple_elements(Node) of
            [F0, _] -> F0;
            [M0, F0, _] -> erl_syntax:module_qualifier(M0, F0);
            _ -> Node
          end;
      _ -> Node
    end.

unfold_function_names(Ns) ->
    F = fun ({Atom, Arity}) ->
                erl_syntax:arity_qualifier(erl_syntax:atom(Atom), erl_syntax:integer(Arity))
        end,
    erl_syntax:list([F(N) || N <- Ns]).

%% Macros are not handled well.
dodge_macros(Type) ->
    F = fun (T) ->
                case erl_syntax:type(T) of
                  macro ->
                      Var = erl_syntax:macro_name(T),
                      VarName0 = erl_syntax:variable_name(Var),
                      VarName = list_to_atom("?" ++ atom_to_list(VarName0)),
                      Atom = erl_syntax:atom(VarName),
                      Atom;
                  _ -> T
                end
        end,
    erl_syntax_lib:map(F, Type).

lay_text_float(Str) -> floating(text(Str)).

lay_follow_beside_text_float(D1, D2, Ctxt) ->
    follow(beside(D1, lay_text_float(" ::")), D2, Ctxt#ctxt.break_indent).

lay_fun_sep(Clauses, Ctxt) ->
    sep([follow(text("fun"), Clauses, Ctxt#ctxt.sub_indent), text("end")]).

lay_expr_argument(none, D, Ctxt) ->
    {_, Prec, _} = inop_prec('#'), maybe_parentheses(D, Prec, Ctxt);
lay_expr_argument(Arg, D, Ctxt) ->
    {PrecL, Prec, _} = inop_prec('#'),
    D1 = beside(lay(Arg, set_prec(Ctxt, PrecL)), D),
    maybe_parentheses(D1, Prec, Ctxt).

lay_parentheses(D, _Ctxt) ->
    beside(lay_text_float("("), beside(D, lay_text_float(")"))).

maybe_parentheses(D, Prec, Ctxt) ->
    case Ctxt#ctxt.prec of
      P when P > Prec -> lay_parentheses(D, Ctxt);
      _ -> D
    end.

lay_string(S, Ctxt) ->
    %% S includes leading/trailing double-quote characters. The segment
    %% width is 2/3 of the ribbon width - this seems to work well.
    W = Ctxt#ctxt.ribbon * 2 div 3,
    lay_string(S, length(S), W).

lay_string(S, L, W) when L > W, W > 0 ->
    %% Note that L is the minimum, not the exact, printed length.
    case split_string(S, W - 1, L) of
      {_S1, ""} -> text(S);
      {S1, S2} ->
          above(text(S1 ++ "\""),
                lay_string([$" | S2], L - W + 1, W))  %" stupid emacs
    end;
lay_string(S, _L, _W) -> text(S).

split_string(Xs, N, L) -> split_string_first(Xs, N, L, []).

%% We only split strings at whitespace, if possible. We must make sure
%% we do not split an escape sequence.
split_string_first([$\s | Xs], N, L, As) when N =< 0, L >= 5 ->
    {lists:reverse([$\s | As]), Xs};
split_string_first([$\t | Xs], N, L, As) when N =< 0, L >= 5 ->
    {lists:reverse([$t, $\\ | As]), Xs};
split_string_first([$\n | Xs], N, L, As) when N =< 0, L >= 5 ->
    {lists:reverse([$n, $\\ | As]), Xs};
split_string_first([$\\ | Xs], N, L, As) ->
    split_string_second(Xs, N - 1, L - 1, [$\\ | As]);
split_string_first(Xs, N, L, As) when N =< -10, L >= 5 ->
    {lists:reverse(As), Xs};
split_string_first([_ | _] = S, N, L, As) -> split_string_next(S, N, L, As);
split_string_first([], _N, _L, As) -> {lists:reverse(As), ""}.

split_string_second([$^, X | Xs], N, L, As) ->
    split_string_first(Xs, N - 2, L - 2, [X, $^ | As]);
split_string_second([$x, ${ | Xs], N, L, As) ->
    split_string_third(Xs, N - 2, L - 2, [${, $x | As]);
split_string_second([X1, X2, X3 | Xs], N, L, As)
    when X1 >= $0, X1 =< $7, X2 >= $0, X2 =< $7, X3 >= $0, X3 =< $7 ->
    split_string_first(Xs, N - 3, L - 3, [X3, X2, X1 | As]);
split_string_second([X1, X2 | Xs], N, L, As)
    when X1 >= $0, X1 =< $7, X2 >= $0, X2 =< $7 ->
    split_string_first(Xs, N - 2, L - 2, [X2, X1 | As]);
split_string_second(S, N, L, As) -> split_string_next(S, N, L, As).

split_string_third([$} | Xs], N, L, As) ->
    split_string_first(Xs, N - 1, L - 1, [$} | As]);
split_string_third([X | Xs], N, L, As)
    when X >= $0, X =< $9; X >= $a, X =< $z; X >= $A, X =< $Z ->
    split_string_third(Xs, N - 1, L - 1, [X | As]);
split_string_third([X | _Xs] = S, N, L, As) when X >= $0, X =< $9 ->
    split_string_next(S, N, L, As).

split_string_next([X | Xs], N, L, As) ->
    split_string_first(Xs, N - 1, L - 1, [X | As]);
split_string_next([], N, L, As) -> split_string_first([], N, L, As).

%% Note that there is nothing in `lay_clauses' that actually requires
%% that the elements have type `clause'; it just sets up the proper
%% context and arranges the elements suitably for clauses.
lay_clauses(Cs, Type, Ctxt) ->
    vertical(seq(Cs, lay_text_float(";"), Ctxt#ctxt{clause = Type}, fun lay/2)).

%% Note that for the clause-making functions, the guard argument
%% can be `none', which has different interpretations in different
%% contexts.
make_fun_clause(P, G, B, Ctxt) -> make_fun_clause(none, P, G, B, Ctxt).

make_fun_clause(N, P, G, B, Ctxt) ->
    D = make_fun_clause_head(N, P, Ctxt), make_case_clause(D, G, B, Ctxt).

make_fun_clause_head(N, P, Ctxt) when N =:= none -> lay_parentheses(P, Ctxt);
make_fun_clause_head(N, P, Ctxt) -> beside(N, lay_parentheses(P, Ctxt)).

make_case_clause(P, G, B, Ctxt) ->
    append_clause_body(B, append_guard(G, P, Ctxt), Ctxt).

make_if_clause(G, B, Ctxt) ->
    G1 = case G of
           none -> text("true");
           _ -> G
         end,
    append_clause_body(B, G1, Ctxt).

append_clause_body(B, D, Ctxt) ->
    append_clause_body(B, D, lay_text_float(" ->"), Ctxt).

append_clause_body(B, D, S, Ctxt) ->
    sep([beside(D, S), nest(Ctxt#ctxt.break_indent, B)]).

append_guard(none, D, _) -> D;
append_guard(G, D, Ctxt) ->
    par([D, follow(text("when"), G, Ctxt#ctxt.sub_indent)], Ctxt#ctxt.break_indent).

lay_bit_types([T], Ctxt) -> lay(T, Ctxt);
lay_bit_types([T | Ts], Ctxt) ->
    beside(lay(T, Ctxt), beside(lay_text_float("-"), lay_bit_types(Ts, Ctxt))).

lay_error_info({L, M, T} = T0, Ctxt) when is_integer(L), is_atom(M) ->
    case catch apply(M, format_error, [T]) of
      S when is_list(S) ->
          case L > 0 of
            true -> beside(text(io_lib:format("~w: ", [L])), text(S));
            _ -> text(S)
          end;
      _ -> lay_concrete(T0, Ctxt)
    end;
lay_error_info(T, Ctxt) -> lay_concrete(T, Ctxt).

lay_concrete(T, Ctxt) -> lay(erl_syntax:abstract(T), Ctxt).

lay_type_assoc(Name, Value, Ctxt) -> lay_type_par_text(Name, Value, "=>", Ctxt).

lay_type_exact(Name, Value, Ctxt) -> lay_type_par_text(Name, Value, ":=", Ctxt).

lay_type_par_text(Name, Value, Text, Ctxt) ->
    Ctxt1 = reset_prec(Ctxt),
    D1 = lay(Name, Ctxt1),
    D2 = lay(Value, Ctxt1),
    par([D1, lay_text_float(Text), D2], Ctxt1#ctxt.break_indent).

lay_application(Name, Arguments, Ctxt) ->
    {PrecL, Prec} = func_prec(), %
    D1 = lay(Name, set_prec(Ctxt, PrecL)),
    As = lay_items(Arguments, reset_prec(Ctxt), fun lay/2),
    D = beside(D1, beside(text("("), beside(As, lay_text_float(")")))),
    maybe_parentheses(D, Prec, Ctxt).

seq([H], _Separator, Ctxt, Fun) -> [Fun(H, Ctxt)];
seq([H | T], Separator, Ctxt, Fun) ->
    [maybe_append(Separator, Fun(H, Ctxt)) | seq(T, Separator, Ctxt, Fun)];
seq([], _, _, _) -> [empty()].

maybe_append(none, D) -> D;
maybe_append(Suffix, D) -> beside(D, Suffix).

vertical([D]) -> D;
vertical([D | Ds]) -> above(D, vertical(Ds));
vertical([]) -> [].

vertical_sep([{D, _}]) -> D;
vertical_sep([{D, empty_line} | Ds]) ->
    above(above(D, text("")), vertical_sep(Ds));
vertical_sep([{D, no_empty_line} | Ds]) -> above(D, vertical_sep(Ds));
vertical_sep([]) -> [].

empty_lines_to_add(Nodes, #ctxt{newline_after_attributes = true}) ->
    lists:duplicate(length(Nodes), empty_line);
empty_lines_to_add([], _Ctxt) -> [];
empty_lines_to_add([Node | Nodes], Ctxt) ->
    AfterThisNode = case erl_syntax:type(Node) of
                      attribute ->
                          AttrName = attribute_name(Node),
                          case is_last_in_list(AttrName, Nodes) of
                            true -> empty_line;
                            false -> no_empty_line
                          end;
                      _ -> empty_line
                    end,
    [AfterThisNode | empty_lines_to_add(Nodes, Ctxt)].

is_last_in_list(_AttrName, []) -> true;
is_last_in_list(spec, _) ->
    false; % we never want to add an empty line after spec
is_last_in_list(AttrName, [Node | _]) ->
    erl_syntax:type(Node) /= attribute orelse attribute_name(Node) /= AttrName.

spaces(N) when N > 0 -> [$\s | spaces(N - 1)];
spaces(_) -> [].

tidy_integer(Node) -> tidy_number(Node, erl_syntax:integer_literal(Node)).

tidy_float(Node) ->
    tidy_number(Node, io_lib:format("~p", [erl_syntax:float_value(Node)])).

%% @doc If we captured the original text for the number, then we use it.
%%      Otherwise, we use the value returned by the parser.
%%      The goal is to preserve things like 16#FADE or -1e-1 instead of turning
%%      them into integers or "pretty printed" floats.
tidy_number(Node, Default) ->
    case erl_syntax:get_pos(Node) of
      L when is_list(L) ->
          case proplists:get_value(text, L, undefined) of
            undefined -> Default;
            Text -> number_from_text(Text, Default)
          end;
      _ -> Default
    end.

%% @doc This function covers the corner case when erl_parse:parse_form/1
%%      (used by ktn_dodger) screws up the text for things like fun x/1 or
%%      -vsn(1) and therefore that text, that was actually captured,
%%      can not be used.
%% NOTE: floats work as "integers" according to string:to_integer/1
number_from_text(Text, Default) ->
    case string:to_integer(Text) of
      {error, no_integer} -> Default;
      {_, _} -> Text
    end.

lay_items(Exprs, Ctxt, Fun) -> lay_items(Exprs, lay_text_float(","), Ctxt, Fun).

lay_items(Exprs, Separator, Ctxt = #ctxt{inline_items = true}, Fun) ->
    par(seq(Exprs, Separator, Ctxt, Fun));
lay_items(Exprs, Separator, Ctxt = #ctxt{inline_items = false}, Fun) ->
    sep(seq(Exprs, Separator, Ctxt, Fun)).

lay_clause_expressions(Exprs, Ctxt = #ctxt{inline_expressions = true}, Fun) ->
    sep(seq(Exprs, lay_text_float(","), Ctxt, Fun));
lay_clause_expressions([H], Ctxt, Fun) -> Fun(H, Ctxt);
lay_clause_expressions([H | T], Ctxt, Fun) ->
    Clause = beside(Fun(H, Ctxt), lay_text_float(",")),
    Next = lay_clause_expressions(T, Ctxt, Fun),
    case is_last_and_before_empty_line(H, T, Ctxt) of
      true -> above(above(Clause, text("")), Next);
      false -> above(Clause, Next)
    end;
lay_clause_expressions([], _, _) -> empty().

is_last_and_before_empty_line(H, [], #ctxt{empty_lines = EmptyLines}) ->
    lists:member(get_pos(H) + 1, EmptyLines);
is_last_and_before_empty_line(H, [H2 | _], #ctxt{empty_lines = EmptyLines}) ->
    get_pos(H2) - get_pos(H) >= 2 andalso lists:member(get_pos(H) + 1, EmptyLines).

get_pos(Node) ->
    case erl_syntax:get_pos(Node) of
      I when is_integer(I) -> I;
      L when is_list(L) -> proplists:get_value(location, L, 0)
    end.


%% =====================================================================
