% 凡例：
% 中核をなす函数は **** で示す．

%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 1996-2019. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% %CopyrightEnd%
%%
-module(proc_lib).


% ****
-spec start_link(
    Module   :: module(),  % `gen' など
    Function :: atom(),    % `init_it' など
    Args     :: [_],
    Time     :: timeout()
) -> term() | {error, Reason :: term()}.
start_link(M, F, A, Timeout) when is_atom(M), is_atom(F), is_list(A) ->
    sync_start_link(?MODULE:spawn_link(M, F, A), Timeout).
      % `sync_start_link' は完了待ちのための函数．下に掲げる．


-spec start_link(
    Module    :: module(),  % `gen' など
    Function  :: atom(),    % `init_it' など
    Args      :: [_],
    Time      :: timeout(),
    SpawnOpts :: [start_spawn_option()]
) -> term() | {error, Reason :: term()}.
start_link(M, F, A, Timeout,SpawnOpts) when is_atom(M), is_atom(F), is_list(A) ->
    ?VERIFY_NO_MONITOR_OPT(M, F, A, Timeout, SpawnOpts),
    sync_start_link(?MODULE:spawn_opt(M, F, A, [link | SpawnOpts]), Timeout).


sync_start_link(Pid, Timeout) ->
  % この函数はプロセスを生成しようとした側で呼び出される．
  % 同期的なプロセス生成のために，
  % 生成したプロセスから初期化の完了通知が送られてくるのを待つ．
  % メッセージを送る側の実装は `proc_lib:init_ack' にあり，
  % これを生成したプロセス側が呼び出さねばならない．
  % `proc_lib:init_ack' を呼び出している実装は `gen' などではなく `gen_server' などにある．
    receive
	{ack, Pid, Return}    -> Return;
	{'EXIT', Pid, Reason} -> {error, Reason}
    after Timeout ->
        kill_flush(Pid),
        {error, timeout}
    end.


% ****
% 新たに生成されたプロセスが，親プロセスに完了通知を送るのに呼び出す．
% 受け取る側の実装は `sync_start_link' などにある．
-spec init_ack(
    Parent :: proc_identifier(), % 親プロセスのPIDまたは登録名．
    Ret :: _ % `proc_lib:start_link' の戻り値にする値．
             % 最終的に直接 `gen_server:start_link' の戻り値になる．
) -> 'ok'.
init_ack(Parent, Return) ->
    Parent ! {ack, self(), Return},
    ok.


% `init_ack/2' の親プロセスを明示しない版．明示しない場合も先祖情報から親がわかる．
-spec init_ack(_) -> 'ok' when
init_ack(Return) ->
    [Parent | _] = get('$ancestors'),
    init_ack(Parent, Return).


% ****
% OTPプロセスを生成して第1引数の函数を走らせる．
% 実装としてはBIFの `erlang:spawn` に `proc_lib:init_p' の処理を咬ませたもの．
-spec spawn(function()) -> pid().
spawn(F) when is_function(F) ->
    Parent = get_my_name(),
      % プロセスを生成しようとしている “親プロセス” のPID（または登録名がある場合は登録名）を返す．
      % ほぼ `self()' と同じ．実装は下へ．
    Ancestors = get_ancestors(),
      % プロセス生成の親子関係に基づく先祖を列挙する．実装は下へ．
    erlang:spawn(?MODULE, init_p, [Parent, Ancestors, F]).


% `proc_lib:spawn/1' の `mfargs()' 版．
-spec spawn(Module :: module(), Function :: atom(), Args :: [_]) -> pid().
spawn(M, F, A) when is_atom(M), is_atom(F), is_list(A) ->
    Parent = get_my_name(),
    Ancestors = get_ancestors(),
    erlang:spawn(?MODULE, init_p, [Parent, Ancestors, M, F, A]).


% 以下はいずれも `proc_lib:spawn/{1,3}' の実装の `erlang:spawn/3' を `erlang:spawn_link/3' に置き換えただけ．
-spec spawn_link(function()) -> pid().
-spec spawn_link(Module :: module(), Function :: atom(), Args :: [_]) -> pid().


% 以下はいずれも `proc_lib:spawn/{1,3}' の実装の `erlang:spawn/3' の適用に
% 第1引数 `Node' を追加して `erlang:spawn/4' を用いるように変更しただけ．
-spec spawn(Node :: node(), Fun :: function()) -> pid().
-spec spawn(Node :: node(), Module :: module(), Function :: atom(), Args :: [_]) -> pid().


% 以下はいずれも `proc_lib:spawn/{2,4}' の実装の `erlang:spawn/4' を `erlang:spawn_link/4' に置き換えただけ．
-spec spawn_link(Node :: node(), Fun :: function()) -> pid().
-spec spawn_link(Node :: node(), Module :: module(), Function :: atom(), Args :: [_]) -> pid().


% これは読む上で独自に追加した型．
% 登録名，または登録名がない場合はPID．
-type proc_identifier() :: atom() | pid().


% ****
% `erlang:spawn' や `erlang:spawn_link' で起動されるプロセスの処理本体．
% すなわちこの函数は新たに生成されたプロセスが呼び出す．
% 基本的には先祖情報の登録と初期化の際の引数を記録しておく以外は
% 単に `Fun()' を（例外を捕捉できるようにして）評価するだけ．
-spec init_p(
    Parent    :: proc_identifier(),   % 親プロセス
    Ancestors :: [proc_identifier()], % 親プロセスの先祖を列挙したリスト
    Fun       :: function()
) -> _.
init_p(Parent, Ancestors, Fun) when is_function(Fun) ->
    put('$ancestors', [Parent | Ancestors]),
      % 先祖情報を自身に備えつける．
    Mfa = erlang:fun_info_mfa(Fun),
      % 函数抽象を `mfargs()' の形へと登録して変換する？
      % 公式ドキュメントには記載がないBIF．
    put('$initial_call', Mfa),
      % 起動時の函数を記録する？
    try
	Fun()
    catch
	Class:Reason:Stacktrace ->
	    exit_p(Class, Reason, Stacktrace)
    end.


% `init_p/3` の `mfargs()' 版．
-spec init_p(
    Parent    :: proc_identifier(),
    Ancestors :: [proc_identifier()],
    M :: atom(), F :: atom(), Args :: [_]
) -> term().
init_p(Parent, Ancestors, M, F, A) when is_atom(M), is_atom(F), is_list(A) ->
    put('$ancestors', [Parent | Ancestors]),
    put('$initial_call', trans_init(M, F, A)),
    init_p_do_apply(M, F, A).


% `init_p/5' だけで使われる．スタックトレースをとるために咬まされている？
init_p_do_apply(M, F, A) ->
    try
	apply(M, F, A)
    catch
	Class:Reason:Stacktrace ->
	    exit_p(Class, Reason, Stacktrace)
    end.


% これを呼び出したプロセスに登録名がある場合はその名前を，ない場合はPIDを返す．
-spec get_my_name() -> proc_identifier().
get_my_name() ->
    case
        proc_info(self(), registered_name)
          % `proc_info' については下へ．ほぼBIFの `erlang:process_info' と同じ．
          % `process_info/2' について：
          %   http://erlang.org/doc/man/erlang.html#process_info-2
          %
          % 公式ドキュメントのspec註釈はちょっと間違っているっぽい．
          % `process_info(Pid, registered_name)` の戻り値は `[] | {registered_name, atom()}` の形式．
          % Name :: atom()
    of
	{registered_name, Name} -> Name;
	_                       -> self()
    end.


% これを呼び出したプロセスの，生成に関する親子関係での先祖をすべて列挙して返す．
% 先祖の情報はプロセス辞書の `$ancestors' というフィールドに記録されている．
-spec get_ancestors() -> [proc_identifier()].
get_ancestors() ->
    case get('$ancestors') of
	A when is_list(A) -> A;
	_                 -> []  % OTPプロセスでない場合は先祖なし扱い．
    end.


proc_info(Pid, Item) when node(Pid) =:= node() ->
  % 呼び出したプロセスと `Pid' が同一ノードにある場合は `process_info' そのまま．
  % `process_info/2' について：
  %   http://erlang.org/doc/man/erlang.html#process_info-2
    process_info(Pid, Item);

proc_info(Pid, Item) ->
  % 呼び出したプロセスと `Pid' が別ノードにある場合は `process_info' を `rpc:call' で実行する．
    case lists:member(node(Pid), nodes()) of
	true -> check(rpc:call(node(Pid), erlang, process_info, [Pid, Item]));
	_    -> hidden
    end.
