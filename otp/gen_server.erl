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
-module(gen_server).


%% `start'，`start_link'，`start_monitor' は `gen:start' のラッパ．
start(Mod, Args, Options)               -> gen:start(?MODULE, nolink, Mod, Args, Options).
start(Name, Mod, Args, Options)         -> gen:start(?MODULE, nolink, Name, Mod, Args, Options).
start_link(Mod, Args, Options)          -> gen:start(?MODULE, link, Mod, Args, Options).
start_link(Name, Mod, Args, Options)    -> gen:start(?MODULE, link, Name, Mod, Args, Options).
start_monitor(Mod, Args, Options)       -> gen:start(?MODULE, monitor, Mod, Args, Options).
start_monitor(Name, Mod, Args, Options) -> gen:start(?MODULE, monitor, Name, Mod, Args, Options).


% `gen:stop' そのまま．
stop(Name)                  -> gen:stop(Name).
stop(Name, Reason, Timeout) -> gen:stop(Name, Reason, Timeout).


call(Name, Request) ->
    case catch gen:call(Name, '$gen_call', Request) of
	{ok, Res}        -> Res;
	{'EXIT', Reason} -> exit({Reason, {?MODULE, call, [Name, Request]}})
    end.

call(Name, Request, Timeout) ->
    case catch gen:call(Name, '$gen_call', Request, Timeout) of
	{ok, Res}        -> Res;
	{'EXIT', Reason} -> exit({Reason, {?MODULE, call, [Name, Request, Timeout]}})
    end.


cast({global, Name}, Request) ->
    catch global:send(Name, cast_msg(Request)),
    ok;

cast({via, Mod, Name}, Request) ->
    catch Mod:send(Name, cast_msg(Request)),
    ok;


cast({Name,Node} = Dest, Request) when is_atom(Name), is_atom(Node) -> do_cast(Dest, Request);
cast(Dest, Request) when is_atom(Dest)                              -> do_cast(Dest, Request);
cast(Dest, Request) when is_pid(Dest)                               -> do_cast(Dest, Request).



do_cast(Dest, Request) ->
    do_send(Dest, cast_msg(Request)),
    ok.


% `cast' で送信するメッセージ．`$gen_cast' というアトムをつける．
cast_msg(Request) -> {'$gen_cast', Request}.


% ほぼ `!` による送信と同じだが，`error' 例外が返ってきても無視する．
do_send(Dest, Msg) ->
    try
        erlang:send(Dest, Msg)
    catch
        error:_ -> ok
    end,
    ok.


% `gen' モジュールによってコールバック的に使われる．
% `gen:init_it2' 参照．
-spec init_it(
    Starter :: pid(),
    Parent  :: pid() | 'self',
    Name    :: atom(),
    Mod     :: module(),  % `gen_server' コールバックモジュール
    Args    :: _,         % `Mod:init/1' に与える引数
    Options :: gen:options()
) -> no_return().
init_it(Starter, self, Name, Mod, Args, Options) ->
    init_it(Starter, self(), Name, Mod, Args, Options);

init_it(Starter, Parent, Name0, Mod, Args, Options) ->
    Name = gen:name(Name0),
    Debug = gen:debug_options(Name, Options),
    HibernateAfterTimeout = gen:hibernate_after(Options),

    case
        init_it(Mod, Args)
          % ほぼ `{ok, Mod:init(Args)}' と同じだが，例外処理もやる．
          % `init_it/2` を参照．
    of
	{ok, {ok, State}} ->
	    proc_lib:init_ack(Starter, {ok, self()}),
              % `gen_server:start_link' などの戻り値として自身のPIDを送る．
	    loop(Parent, Name, State, Mod, infinity, HibernateAfterTimeout, Debug);
              % ループに入る．

	{ok, {ok, State, Timeout}} ->
	    proc_lib:init_ack(Starter, {ok, self()}),
	    loop(Parent, Name, State, Mod, Timeout, HibernateAfterTimeout, Debug);

	{ok, {stop, Reason}} ->
            % ※原文コメント：
	    %% For consistency, we must make sure that the
	    %% registered name (if any) is unregistered before
	    %% the parent process is notified about the failure.
	    %% (Otherwise, the parent process could get
	    %% an 'already_started' error if it immediately
	    %% tried starting the process again.)
	    gen:unregister_name(Name0),
	    proc_lib:init_ack(Starter, {error, Reason}),
	    exit(Reason);

	{ok, ignore} ->
	    gen:unregister_name(Name0),
	    proc_lib:init_ack(Starter, ignore),
	    exit(normal);
	{ok, Else} ->
	    Error = {bad_return_value, Else},
	    proc_lib:init_ack(Starter, {error, Error}),
	    exit(Error);
	{'EXIT', Class, Reason, Stacktrace} ->
	    gen:unregister_name(Name0),
	    proc_lib:init_ack(Starter, {error, terminate_reason(Class, Reason, Stacktrace)}),
	    erlang:raise(Class, Reason, Stacktrace)
    end.


% `Mod:init/1' に `Args' を適用し，初期化を行なう．
% 例外は `throw' のものだけ捕捉して正常起動とする（形式は `InitRet' に従っていなければならない）．
-spec init_it(
    Mod  :: module(),
    Args :: _,
) -> {'ok', InitRet}
   | {'EXIT', ExnClass :: 'exit' | 'error', Reason :: _, Stacktrace :: _}
when
    InitRet :: {ok, State} | {ok, State, timeout()} | ignore | {stop, Reason :: _},
    State :: _.
init_it(Mod, Args) ->
    try
	{ok, Mod:init(Args)}
    catch
	throw:R   -> {ok, R};
	Class:R:S -> {'EXIT', Class, R, S}
    end.
