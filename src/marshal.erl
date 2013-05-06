-module(marshal).
-export([decode/1, decode_file/1, encode/1]).

-ifdef(TEST).
-export([test/0]).
-endif.

-include("marshal.hrl").

decode_file(Filename) ->
    case file:read_file(Filename) of
        {ok, D} -> decode(D);
        Any -> Any
    end.

%% decode/1

decode(<<Major:8, Minor:8, D/binary>>) when Major =:= ?MARSHAL_MAJOR, Minor =:= ?MARSHAL_MINOR ->
    decode(D);
decode(D) ->
    Acceptor = self(),
    spawn(fun() -> decode(D, Acceptor) end),
    receive
        {ok, Decoded} -> Decoded;
        error         -> malformed
    end.

%% encode/1

encode(Term) ->
    Binary = encode_element(Term),
    <<?MARSHAL_MAJOR:8, ?MARSHAL_MINOR:8, Binary/binary>>.

%% decode/2

decode(D, Pid) when is_pid(Pid) ->
    try
        Decoded = decode(D, []),
        Pid ! {ok, Decoded}
    catch error:_ ->
        Pid ! error
    end;

decode(<<>>, Acc) ->
    lists:reverse(Acc);
decode(<<T:8, D/binary>>, Acc) ->
    {Element, D2} = decode_element(T, D),
    decode(D2, [Element | Acc]).

%% decode_element/2

decode_element(?TYPE_NIL, <<D/binary>>) -> {nil, D};
decode_element(?TYPE_TRUE, <<D/binary>>) -> {true, D};
decode_element(?TYPE_FALSE, <<D/binary>>) -> {false, D};

decode_element(?TYPE_FIXNUM, <<S:8, D/binary>>) -> decode_fixnum(S, D);
decode_element(?TYPE_FLOAT, <<S:8, D/binary>>) -> decode_float(S, D);

decode_element(?TYPE_STRING, <<S:8, D/binary>>) -> decode_string(S, D);
decode_element(?TYPE_REGEXP, <<S:8, D/binary>>) -> decode_regexp(S, D);

decode_element(?TYPE_ARRAY, <<S:8, D/binary>>) -> decode_array(S, D);
decode_element(?TYPE_HASH, <<S:8, D/binary>>) -> decode_hash(S, D);

decode_element(?TYPE_SYMBOL, <<S:8, D/binary>>) -> decode_symbol(S, D);
decode_element(?TYPE_SYMLINK, <<N:8, D/binary>>) -> decode_symlink(N, D);
decode_element(?TYPE_UCLASS, <<D/binary>>) -> decode_uclass(D);
decode_element(?TYPE_IVAR, <<T:8, D/binary>>) -> decode_element_with_ivars(T, D);
decode_element(?TYPE_LINK, <<N:8, D/binary>>) -> decode_link(N, D);

decode_element(_T, <<T:8, D/binary>>) -> decode_element(T, D).

%% encode_element/1

encode_element(nil) -> <<?TYPE_NIL:8>>;
encode_element(null) -> encode_element(nil);
encode_element(undefined) -> encode_element(nil);
encode_element(true) -> <<?TYPE_TRUE:8>>;
encode_element(false) -> <<?TYPE_FALSE:8>>;
encode_element(A) when is_integer(A), A =< 2147483647, A >= -2147483648 -> encode_fixnum(A);
encode_element(A) when is_integer(A), A > 2147483647 -> encode_bignum(A);
encode_element(A) when is_integer(A), A < 2147483648 -> encode_bignum(A);
encode_element(A) when is_float(A) -> encode_float(A);
encode_element(A) when is_atom(A) -> encode_symbol(A);
encode_element({string, A}) -> encode_string(A);
encode_element({regexp, A}) -> encode_regexp(A);
encode_element({array, A}) -> encode_array(A);
encode_element({hash, A}) -> encode_hash(A);
encode_element({symbol, A}) -> encode_symbol(A).

%% Base types - decode

decode_fixnum(S, D) ->
    unpack(S, D).

decode_float(S, D) ->
    {Float, D2} = decode_string(S, D),
    {list_to_float(Float), D2}.

decode_string(S, D) ->
    {Size, D2} = unpack(S, D),
    {String, D3} = read_bytes(D2, Size),
    {put_value(String), D3}.

decode_regexp(S, D) ->
    {RegExp, D2} = decode_string(S, D),
    <<_:8, D3/binary>> = D2,
    {{regexp, put_value(RegExp)}, D3}.

%% Base types - encode

encode_fixnum(A) ->
    Binary = pack(A),
    <<?TYPE_FIXNUM:8, Binary/binary>>.

encode_float(A) ->
    Binary = list_to_binary(float_to_list(A)),
    <<?TYPE_FLOAT:8, Binary/binary>>.

encode_bignum(A) ->
    Sign = case A > 0 of
               true -> $+;
               _ -> $-
           end,
    Nbits = nbits_unsigned(A),
    Size = pack(trunc(Nbits / 16)),
    <<?TYPE_BIGNUM:8, Sign:8, Size/binary, A:Nbits/little-unsigned>>.

encode_string(A) ->
    Binary = unicode:characters_to_binary(A,unicode),
    Size = pack(lists:flatlength(A)),
    <<?TYPE_STRING:8, Size/binary, Binary/binary>>.

encode_regexp(A) ->
    Binary = unicode:characters_to_binary(A),
    Size = pack(lists:flatlength(A)),
    <<?TYPE_REGEXP:8, Size/binary, Binary/binary>>.

encode_array(List) ->
    Size = pack(lists:flatlength(List)),
    Binary = encode_array(List, <<>>),
    <<?TYPE_ARRAY:8, Size/binary, Binary/binary>>.

encode_array([], Acc) ->
    Acc;
encode_array(List, Acc) ->
    [Head | Tail] = List,
    Binary = encode_element(Head),
    encode_array(Tail, <<Acc/binary, Binary/binary>>).

encode_symbol(A)->
    Binary = unicode:characters_to_binary(atom_to_list(A),unicode),
    Size = pack(lists:flatlength(atom_to_list(A))),
    <<?TYPE_SYMBOL:8, Size/binary, Binary/binary>>.

encode_hash(A)->
    Size = pack(length(A)),
    Binary = encode_hash(A,<<>>),
    <<?TYPE_HASH:8, Size/binary, Binary/binary>>.

encode_hash([],Acc)->
    Acc;

encode_hash(List,Acc)->
    [{Symbol,Term}|Tail] = List,
    BinarySymbol = encode_symbol(Symbol),
    BinaryTerm = encode_element(Term),
    encode_hash(Tail,<<Acc/binary, BinarySymbol/binary, BinaryTerm/binary>>).

%% Array

decode_array(S, D) ->
    {Size, D2} = unpack(S, D),
    decode_array(D2, Size, []).

decode_array(D, 0, Acc) ->
    {lists:reverse(Acc), D};
decode_array(D, Size, Acc) ->
    <<T:8, D2/binary>> = D,
    {Element, D3} = decode_element(T, D2),
    decode_array(D3, Size - 1, [Element | Acc]).

%% Hash

decode_hash(S, D) ->
    {Size, D2} = unpack(S, D),
    decode_hash(D2, Size, []).

decode_hash(D, 0, Acc) ->
    {lists:reverse(Acc), D};
decode_hash(D, Size, Acc) ->
    {{Key, Value}, D2} = decode_hash_element(D),
    decode_hash(D2, Size - 1, [{Key, Value} | Acc]).

decode_hash_element(<<T:8, D/binary>>) ->
    {Key, D2} = decode_element(T, D),
    <<T2:8, D3/binary>> = D2,
    {Value, D4} = decode_element(T2, D3),
    {{Key, Value}, D4}.

decode_symbol(S, D) ->
    {Size, D2} = unpack(S, D),
    {_Symbol, D3} = read_bytes(D2, Size),
    Symbol = list_to_atom(_Symbol),
    {put_symbol(Symbol), D3}.

decode_symlink(N, D) ->
    {get_symbol(N), D}.

decode_link(N, D) ->
    {get_value(N), D}.

decode_uclass(<<T:8, D/binary>>) ->
    {_ClassName, D2} = decode_element(T, D),
    <<T2:8, D3/binary>> = D2,
    decode_element(T2, D3).

%% Objects with instance variables

decode_element_with_ivars(T = ?TYPE_STRING, D) ->
    {Element, DI} = decode_element(T, D),
    {_,       D2} = decode_ivars(DI),
    {Element, D2};

decode_element_with_ivars(T, D) ->
    {Element, DI} = decode_element(T, D),
    {Ivars,   D2} = decode_ivars(DI),
    {[Element, Ivars], D2}.

decode_ivars(<<S:8, D/binary>>) ->
    {Count, D2} = unpack(S, D),
    decode_ivars(D2, Count, []).

decode_ivars(D, 0, Acc) ->
    {lists:reverse(Acc), D};
decode_ivars(D, Count, Acc) ->
    {Ivar, D2} = decode_ivar(D),
    decode_ivars(D2, Count - 1, [Ivar | Acc]).

decode_ivar(D) ->
    <<Tn:8, Dn/binary>> = D,
    {Name,  D2} = decode_element(Tn, Dn),
    <<Tv:8, Dv/binary>> = D2,
    {Value, D3} = decode_element(Tv, Dv),
    {{Name, Value}, D3}.

%% Helpers

pack(0) ->
    <<0:8>>;
pack(N) when N >= 1, N =< 122 ->
    N2 = N + 5,
    <<N2:8>>;
pack(N) when N =< -1, N >= -122 ->
    N2 = N - 5,
    <<N2:8>>;
pack(N) when N >= 123, N =< 2147483647 ->
    <<4:8, N:32/little-unsigned>>;
pack(N) when N =< -123, N >= -2147483648 ->
    <<-4:8, N:32/little-unsigned>>.

unpack(N, D) when N =:= 0 ->
    {N, D};
unpack(N, D) when N >= 6, N =< 127 ->
    {N - 5, D};
unpack(N, D) when N >= 1, N =< 4 ->
    {N2, D2} = read_bytes(D, N),
    N3 = read_integer(list_to_binary(N2 ++ [0, 0, 0])),
    {N3, D2};
unpack(N, D) when N =< -6, N >= -128 ->
    {N + 5, D}.

read_integer(<<N:32/little-unsigned>>) ->
    N;
read_integer(<<N:32/little-unsigned, _>>) ->
    N.

read_bytes(Data, Count) ->
    read_bytes(Data, Count, []).

read_bytes(Data, 0, Acc) ->
    {Acc, Data};
read_bytes(<<Byte:8, Data/binary>>, Count, Acc) ->
    read_bytes(Data, Count - 1, Acc ++ [Byte]).

nbits_unsigned(XS) -> % Necessary bit size for an integer value.
    Min = trunc(math:log(XS) / math:log(2)) + 1,
    case Min rem 16 of
        0 -> Min;
        _ -> Min - (Min rem 16) + 16
    end.

%% Strings and symbols are cached in two different hash tables
%% in the Ruby source. The first (arg->symbols) contains symbols
%% encountered while marshaling/loading, and reused ones are
%% represented via a TYPE_SYMLINK; the second (arg->data) contains
%% other data types, and reused ones are represented via a TYPE_LINK.
%%
get_value(Num)  -> get({value,  Num}).
get_symbol(Num) -> get({symbol, Num}).

put_value(Val)  -> table_put(value,  Val).
put_symbol(Sym) -> table_put(symbol, Sym).

table_put(Type, Value) ->
    case table_exists(Type, Value) of
        true  -> do_nothing;
        false ->
            %% Get the count of elements with the given Type
            %% stored in the process dictionary.
            %%
            %% The dictionary contains, e.g:
            %% [{{value,  0}, "prot"}, {{value,  6}, 3.141457},
            %%  {{symbol, 0}, "fooX"}, {{symbol, 6}, "barbaz"}]
            %%
            Count = lists:foldl(fun(E, Acc) ->
                case E of
                    {{Type, _}, _} -> Acc + 1;
                    _              -> Acc
                end
            end, 0, get()),

            %% If there are no elements of type Type, this value
            %% ID is 0, else it is the count of Type elements plus
            %% 5. Don't ask me why: that's how the Ruby marshaller
            %% works! :-).
            %%
            Num = case Count of
                0 -> 0;
                N -> N + 5
            end,

            put({Type, Num}, Value)
    end,

    Value.

table_exists(Type, Value) ->
    Existing = lists:filter(fun(E) ->
        case E of
            {{Type, _}, Value} -> true;
            _                  -> false
        end
    end, get()),

    case length(Existing) of
        1 -> true;
        0 -> false
    end.

%% Tests

-ifdef(TEST).

test() ->
    Res = [
           {fixnum_test, fixnum_test()},
           {float_test, float_test()},
           {string_test, string_test()},
           {regexp_test, regexp_test()},
           {array_test, array_test()},
           {hash_test, hash_test()}
          ],
    test_out(Res).

test_out([]) ->
    done;
test_out([{Test, Res} | T]) ->
    io:format("~p: ~p~n", [Test, Res]),
    test_out(T).

fixnum_test() ->
    need_implementation.

float_test() ->
    [3.141592653589793] =:= decode_file("tests/float_test.bin").

string_test() ->
    ["Hello, world !!!"] =:= decode_file("tests/string_test.bin").

regexp_test() ->
    need_implementation.

array_test() ->
    [[2, 4, 8, 16, 32]] =:= decode_file("tests/array_test.bin").

hash_test() ->
    need_implementation.

-endif.
