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

%% プロセスの登録名として与えられるデータの型．
-type emgr_name() ::
    {'local' , atom()}
  | {'global', term()}
  | {'via'   , Module :: module(), Name :: term()}.

-type start_ret() ::
    {'ok', pid()} | 'ignore' | {'error', term()}.

-type debug_flag() ::
    'trace' | 'log' | 'statistics' | 'debug' | {'logfile', string()}.

%% `gen:start/{5,6}' に対するオプション．
-type option() ::
    {'timeout', timeout()}
  | {'debug', [debug_flag()]}
  | {'hibernate_after', timeout()}
  | {'spawn_opt', [proc_lib:spawn_option()]}.

-type options() :: [option()].

-type server_ref() ::
   pid() | atom() | {atom(), node()} | {global, term()} | {via, module(), term()}.

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
      % 登録名なしの場合は新たに起動したプロセス

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
