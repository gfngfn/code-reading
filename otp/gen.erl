% 凡例：
% 中核をなす函数は **** で示す．

%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 1996-2018. All Rights Reserved.
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
-module(gen).

-define(default_timeout, 5000).

%% リンクやモニタの指定のための型．
-type linkage() ::
    'monitor' | 'link' | 'nolink'.

%% プロセスを登録する際の指定方法として与えられるデータの型．
-type emgr_name() ::
    {'local', atom()}
  | {'global', _}
  | {'via', Module :: module(), Name :: _}.

-type start_ret() ::
    {'ok', pid()} | 'ignore' | {'error', _}.

-type debug_flag() ::
    'trace' | 'log' | 'statistics' | 'debug' | {'logfile', string()}.

%% `gen:start/{5,6}' に対するオプション．
-type option() ::
    {'timeout', timeout()}
  | {'debug', [debug_flag()]}
  | {'hibernate_after', timeout()}
  | {'spawn_opt', [proc_lib:spawn_option()]}.

-type options() :: [option()].

%% プロセスを指し示すデータの型．
-type server_ref() ::
    pid()
  | atom()
  | {atom(), node()}
  | {'global', _}
  | {'via', module(), _}.

-type request_id() :: term().


% ****
-spec start(
    GenMod  :: module(), % `init_it/6' をもつコールバック的モジュール．`gen_server' など．
    LinkP   :: linkage(),
    Name    :: emgr_name(),
    Mod     :: module(), % `GenMod' が要請するビヘイビアに対するコールバックモジュール，
    Args    :: _,        % `Mod' の初期化函数（`Mod:init/1' など）に渡す引数．
    Options :: options()
) -> start_ret().
start(GenMod, LinkP, Name, Mod, Args, Options) ->
  % ↓名前が既に登録済みかどうかのバリデーションを行なう．
  % もっと奥底の，実際に `register_name' を呼ぶ処理の箇所でもエラー処理が行なわれるが，
  % ここで早いうちにもやっておくらしい．
    case where(Name) of
        undefined -> do_spawn(GenMod, LinkP, Name, Mod, Args, Options);
        Pid       -> {error, {already_started, Pid}}
    end.


% `gen:start/6' の登録名なし版．
-spec start(module(), linkage(), module(), term(), options()) -> start_ret().
start(GenMod, LinkP, Mod, Args, Options) ->
    do_spawn(GenMod, LinkP, Mod, Args, Options).


% ****
% `start_link' などに薄くラップされている函数．すなわち `start_link' を呼び出したプロセスが呼び出す．
% ※原文コメント：
%% Spawn the process (and link) maybe at another node.
%% If spawn without link, set parent to ourselves 'self'!!!
-spec do_spawn(
    GenMod  :: module(), % `init_it/6' をもつコールバック的モジュール．`gen_server' など．
    LinkP   :: linkage(),
    Mod  :: module(), % `GenMod' が要請するビヘイビアに対するコールバックモジュール，
    Args :: _,        % `Mod' の初期化函数（`Mod:init/1' など）に渡す引数．
    Options :: options()
) -> start_ret().
do_spawn(GenMod, link, Mod, Args, Options) ->
    Time = timeout(Options),
      % `timeout/1' はオプション指定からタイムアウト `timeout' の値を取り出す．ない場合は `infinity'．
      % 下の `spawn_opts/1' も同様に `spawn_opt' の値を取り出す．
    proc_lib:start_link(
        ?MODULE, init_it,
        [GenMod, self(), self(), Mod, Args, Options],
        Time, spawn_opts(Options));
      % 同期的にプロセスを開始する．
      % `proc_lib:start_link' は `proc_lib' 参照．

do_spawn(GenMod, monitor, Mod, Args, Options) ->
    Time = timeout(Options),
    Ret =
        proc_lib:start_monitor(
            ?MODULE, init_it,
            [GenMod, self(), self(), Mod, Args, Options],
            Time, spawn_opts(Options)),
    monitor_return(Ret);

do_spawn(GenMod, _, Mod, Args, Options) ->
    Time = timeout(Options),
    proc_lib:start(
        ?MODULE, init_it,
        [GenMod, self(), self, Mod, Args, Options],
        Time, spawn_opts(Options)).
      % リンクもモニタもしない場合は，`init_it/6' の第3引数を `self' というアトムにする．


% `do_spawn/6' は，`do_spawn/5' の実装の `init_it/6' が `init_it/7' を用いて引数に `Name' を追加したもの
-spec do_spawn(
    GenMod  :: module(),
    LinkP   :: linkage(),
    Name    :: emgr_name(),
    Mod  :: module(),
    Args :: _,
    Options :: options()
) -> start_ret().


% ****
% 新たに起動したプロセスが開始処理として呼び出す函数．
% 実装としてはBIFの `erlang:spawn' などがこれを直接呼び出すのではなく，
% `proc_lib:start' の評価中で `proc_lib:init_p/5' に渡されて使われる．
-spec init_it(
    GenMod  :: module(),
    Starter :: pid(), % `start' や `start_link' を呼び出したプロセス．
    Parent  :: pid() | 'self',  % リンク上の親プロセス．
                                % リンクする場合は `Starter' と同じ，リンクしない場合は `self' というアトム．
    Mod  :: module(),
    Args :: _,
    Options :: options()
) -> 'ok'.
init_it(GenMod, Starter, Parent, Mod, Args, Options) ->
    init_it2(GenMod, Starter, Parent, self(), Mod, Args, Options).


% ****
% `init/6' の登録名あり版．ここで実際に名前を登録する．
init_it(GenMod, Starter, Parent, Name, Mod, Args, Options) ->
    case register_name(Name) of
        true         -> init_it2(GenMod, Starter, Parent, Name, Mod, Args, Options);
        {false, Pid} -> proc_lib:init_ack(Starter, {error, {already_started, Pid}})
    end.
      % 自身の名前を登録する．ここで失敗した場合は `proc_lib:init_ack/2' を通じて
      % `start' や `start_link' を呼び出したプロセスに戻り値 `{error, …}' を返す．


% ****
-spec init_it2(
    GenMod  :: module(),
    Starter :: pid(),
      % `start' や `start_link' を呼び出したプロセス．
    Parent  :: pid() | 'self',
      % リンク上の親プロセス．
      % リンクする場合は `Starter' と同じ，リンクしない場合は `self' というアトム．
    Name    :: emgr_name() | pid(),
      % 新たに立ち上げたプロセスの登録名の指定，または登録名なしの場合はPID．
    Mod  :: module(),
    Args :: _,
    Options :: options()
) -> no_return().
  % 起動に成功した場合は `Mod'（`gen_server' など）の実装にしたがってループに入るので戻ってこない．
  % 起動に失敗した場合や，`Mod' が `gen_server' コールバックの場合に `Mod:init(Args)' が `ignore' を返した場合などは
  % 例外によってプロセスが終了する．
init_it2(GenMod, Starter, Parent, Name, Mod, Args, Options) ->
    GenMod:init_it(Starter, Parent, Name, Mod, Args, Options).
      % ここでコールバック的な `init_it/6' が呼ばれる．
      % `gen_server:init_it/6' など．
      % `Mod' は `GenMod' が要請するビヘイビアに対するコールバックモジュール，
      % `Args' はその初期化函数（`Mod:init/1' など）に対する引数．


% ノード内ローカルに通用する登録名またはPIDを得る．
-spec name(emgr_name() | pid()) -> atom() | pid().
name({local, Name})        -> Name;
name({global, Name})       -> Name;
name({via, _, Name})       -> Name;
name(Pid) when is_pid(Pid) -> Pid.


% `gen:call/4' のタイムアウト無指定版．デフォルトのタイムアウト値を用いる．
call(Process, Label, Request) ->
    call(Process, Label, Request, ?default_timeout).

% 送信先の指定がPIDの場合．
% ※原文コメント：
%% Optimize a common case.
-spec call(
    Process :: gen:server_ref(),  % 送信先の指定
    Label   :: atom(),            % `$gen_call' など
    Request :: _,
    Timeout :: timeout()
) -> {'ok', _}.
  % 送信失敗の場合は `exit' 例外が送出される．
  % `gen_server:call' の実装などでは，この例外が `catch' プリミティヴによって捕捉されている．
call(Process, Label, Request, Timeout) when
        is_pid(Process), Timeout =:= infinity orelse is_integer(Timeout) andalso Timeout >= 0 ->
    do_call(Process, Label, Request, Timeout);

% 送信先の指定が（同一ノード内の）登録名の場合．
call(Process, Label, Request, Timeout) when
        Timeout =:= infinity; is_integer(Timeout), Timeout >= 0 ->
    Fun = fun(Pid) -> do_call(Pid, Label, Request, Timeout) end,
    do_for_proc(Process, Fun).
      % 単に登録名 `Process' を `whereis/1' でPIDに変換して `Fun' に適用するだけ．
      % 登録名として存在しない場合は `exit(noproc)' で落ちる．


-spec do_for_proc(
    Dest :: gen:server_ref(),
    Fun  :: fun((pid() | {Name :: atom(), Node :: node()}) -> Ret)) -> Ret
    when Ret :: _.
do_for_proc(Pid, Fun) when is_pid(Pid) ->
    Fun(Pid);

do_for_proc(Name, Fun) when is_atom(Name) ->
    case whereis(Name) of
        Pid when is_pid(Pid) -> Fun(Pid);
        undefined            -> exit(noproc)
    end;

do_for_proc(Process, Fun)
    when ((tuple_size(Process) == 2 andalso element(1, Process) == global)
        orelse (tuple_size(Process) == 3 andalso element(1, Process) == via)) ->
  % 第1引数 `Process' が `{global, _}' または `{via, _, _}' の形のとき
    case where(Process) of
        Pid when is_pid(Pid) ->
            Node = node(Pid),
            try
                Fun(Pid)
            catch
                exit:{nodedown, Node} ->
                    % ※原文コメント：
                    %% A nodedown not yet detected by global,
                    %% pretend that it was.
                    exit(noproc)
            end;

        undefined ->
            exit(noproc)
    end;

do_for_proc({Name, Node}, Fun) when Node =:= node() ->
    do_for_proc(Name, Fun);

do_for_proc({_Name, Node} = Process, Fun) when is_atom(Node) ->
    if
        node() =:= nonode@nohost -> exit({nodedown, Node});
        true                     -> Fun(Process)
    end.


-spec do_call(
    Process :: pid() | atom() | {Name :: atom(), Node :: node()},
                          % 送信先．ローカルな場合はPID，別ノードの場合は登録名とノード名の組
    Label   :: atom(),    % ラベル．`$gen_call' など
    Request :: _,         % `gen_server:call' などに与えられた送信内容
    Timeout :: timeout()  % レスポンスを待つ最大時間
) -> {'ok', _}.
do_call(Process, Label, Request, Timeout) when is_atom(Process) =:= false ->
    Mref = erlang:monitor(process, Process),
      % `erlang:monitor' は第2引数としてPIDに限らず
      % `pid() | atom() | {Name :: atom(), Node :: node()}' の形式を受けつける．
      % 参考：
      %   http://erlang.org/doc/man/erlang.html#monitor-2

    % ※原文コメント：
    %% OTP-21:
    %% Auto-connect is asynchronous. But we still use 'noconnect' to make sure
    %% we send on the monitored connection, and not trigger a new auto-connect.
    erlang:send(Process, {Label, {self(), Mref}, Request}, [noconnect]),
      % メッセージの形式は `{ラベル, {送信元PID, 1回の送受信に使うモニタ参照}, リクエスト本体}'

    receive
        {Mref, Reply} ->
          % レスポンスが正常に受信できたとき
            erlang:demonitor(Mref, [flush]),
            {ok, Reply};

        {'DOWN', Mref, _, _, noconnection} ->
          % 送信先がノードごと接続できないとき
            Node = get_node(Process),
            exit({nodedown, Node});

        {'DOWN', Mref, _, _, Reason} ->
          % 送信先プロセスが何らかの理由で終了したとき，または既に終了していたとき
          % （`erlang:monitor` は既に終了しているプロセスにモニタを張ろうとしたら
          % 即座に自身のメールボックスに `{'DOWN', Mref, process, Process, noproc}' を入れる）
            exit(Reason)

    after Timeout ->
      % 制限時間内にレスポンスが返ってこなかったとき
        erlang:demonitor(Mref, [flush]),
        exit(timeout)
    end.
