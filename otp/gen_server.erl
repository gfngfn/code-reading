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


% `start'，`start_link'，`start_monitor' は `gen:start' のラッパ．
% `Name :: gen:emgr_name()'
start(Mod, Args, Options)               -> gen:start(?MODULE, nolink, Mod, Args, Options).
start(Name, Mod, Args, Options)         -> gen:start(?MODULE, nolink, Name, Mod, Args, Options).
start_link(Mod, Args, Options)          -> gen:start(?MODULE, link, Mod, Args, Options).
start_link(Name, Mod, Args, Options)    -> gen:start(?MODULE, link, Name, Mod, Args, Options).
start_monitor(Mod, Args, Options)       -> gen:start(?MODULE, monitor, Mod, Args, Options).
start_monitor(Name, Mod, Args, Options) -> gen:start(?MODULE, monitor, Name, Mod, Args, Options).


% `gen:stop' そのまま．
stop(Name)                  -> gen:stop(Name).
stop(Name, Reason, Timeout) -> gen:stop(Name, Reason, Timeout).


-spec call(Name :: gen:server_ref(), Request :: _) -> Reply :: _.
call(Name, Request) ->
    case catch gen:call(Name, '$gen_call', Request) of
        {ok, Res}        -> Res;
        {'EXIT', Reason} -> exit({Reason, {?MODULE, call, [Name, Request]}})
    end.

-spec call(Name :: gen:server_ref(), Request :: _, timeout()) -> Reply :: _.
call(Name, Request, Timeout) ->
    case catch gen:call(Name, '$gen_call', Request, Timeout) of
        {ok, Res}        -> Res;
        {'EXIT', Reason} -> exit({Reason, {?MODULE, call, [Name, Request, Timeout]}})
    end.


% 非同期的な送信を行なうための，公開された函数．
% 奥で使われている `do_send' の実装を見るとわかるが，
% 通常の `!' と同様に既に存在しないプロセスのPIDを与えても失敗しないだけでなく，
% `Dest' に登録名として存在しないアトムなどを与えても失敗しないことに注意
% （`!' は登録名として存在しないアトムなどを与えると `badarg' の `error' 例外送出）．
-spec cast(Dest :: gen:server_ref(), Request :: _) -> 'ok'.
cast({global, Name}, Request) ->
  % Name :: _
    catch global:send(Name, cast_msg(Request)),
    ok;

cast({via, Mod, Name}, Request) ->
    catch Mod:send(Name, cast_msg(Request)),
    ok;

cast({Name, Node} = Dest, Request) when is_atom(Name), is_atom(Node) -> do_cast(Dest, Request);
cast(Dest, Request) when is_atom(Dest)                               -> do_cast(Dest, Request);
cast(Dest, Request) when is_pid(Dest)                                -> do_cast(Dest, Request).


% 呼び出し時に `Dest' が実際に `gen:server_ref()' の形式であることが保証された，`cast' のすぐ内側の函数．
-spec do_cast(Dest :: gen:server_ref(), Request :: _) -> 'ok'.
do_cast(Dest, Request) ->
    do_send(Dest, cast_msg(Request)),
    ok.


% `cast' で送信するメッセージ．`$gen_cast' というアトムをつける．
cast_msg(Request) -> {'$gen_cast', Request}.


% ほぼ `!` による送信と同じだが，`error' 例外が返ってきても無視する．
% `Dest' が `gen:server_ref()' の形式を満たしている限り，エラーは `Dest' が存在しない登録名だった場合のみ．
-spec do_send(Dest :: gen:server_ref(), Msg :: _) -> 'ok'.
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
    Starter :: pid(),          % `gen_server:start_link' などを呼び出したプロセスのPID．
    Parent  :: pid() | 'self', % リンクしている場合は `Starter' と同じ，リンクしていない場合は `self'．
    Name    :: gen:emgr_name() | pid(),
    Mod  :: module(),  % `gen_server' コールバックモジュール
    Args :: _,         % `Mod:init/1' に与える引数
    Options :: gen:options()
) -> no_return().
init_it(Starter, self, Name, Mod, Args, Options) ->
    init_it(Starter, self(), Name, Mod, Args, Options);

init_it(Starter, Parent, Name0, Mod, Args, Options) ->
    Name = gen:name(Name0),
      % Name :: atom() | pid()
    Debug = gen:debug_options(Name, Options),
      % Debug :: [sys:dbg_opt()]
      %
      % `gen:debug_options/1' はオプション中の `debug' を取り出す．
      % 無指定の場合や不正な指定の場合は空リスト．
    HibernateAfterTimeout = gen:hibernate_after(Options),
      % HibernateAfterTimeout :: timeout()
      %
      % `gen:hibernate_after/1` はオプション中の `hibernate_after' を取り出す．
      % 指定がない場合は `infinity'．

    case
        init_it(Mod, Args)
          % ほぼ `{ok, Mod:init(Args)}' と同じだが，例外処理もやる．
          % `init_it/2` を参照．
    of
        {ok, {ok, State}} ->
          % 正常に初期化された場合
            proc_lib:init_ack(Starter, {ok, self()}),
              % `gen_server:start_link' などの戻り値にするために自身のPIDを送る．
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
          % 起動中止の場合
            gen:unregister_name(Name0),
            proc_lib:init_ack(Starter, ignore),
            exit(normal);

        {ok, Else} ->
          % `Mod:init(Args)' の戻り値の形式が不正な場合
            Error = {bad_return_value, Else},
            proc_lib:init_ack(Starter, {error, Error}),
            exit(Error);

        {'EXIT', Class, Reason, Stacktrace} ->
          % `Mod:init(Args)' の評価中に `exit' か `error' の例外が生じた場合
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
   | {'EXIT', Class :: 'exit' | 'error', Reason :: _, Stacktrace :: _}
when
    InitRet :: {ok, State} | {ok, State, timeout()} | ignore | {stop, Reason :: _},
    State   :: _.
init_it(Mod, Args) ->
    try
        {ok, Mod:init(Args)}
    catch
        throw:R   -> {ok, R};
        Class:R:S -> {'EXIT', Class, R, S}
    end.


% ****
% メインループ
-spec loop(
    Parent :: pid(),  % リンクされている場合は起動した親プロセスのPID，リンクされていない場合は自分自身のPID．
    Name   :: atom() | pid(),
    State  :: _,        % 状態
    Mod    :: module(), % `gen_server' コールバックモジュール
    Time   :: {'continue', _} | 'hibernate' | timeout(),
    HibernateAfterTimeout :: timeout(),
    Debug                 :: [sys:dbg_opt()]
) -> no_return().
loop(Parent, Name, State, Mod, {continue, Continue} = Msg, HibernateAfterTimeout, Debug) ->
    Reply = try_dispatch(Mod, handle_continue, Continue, State),
    case Debug of
        [] ->
            handle_common_reply(Reply, Parent, Name, undefined, Msg, Mod,
                HibernateAfterTimeout, State);
        _ ->
            Debug1 = sys:handle_debug(Debug, fun print_event/3, Name, Msg),
            handle_common_reply(Reply, Parent, Name, undefined, Msg, Mod,
                HibernateAfterTimeout, State, Debug1)
    end;

loop(Parent, Name, State, Mod, hibernate, HibernateAfterTimeout, Debug) ->
  % 休眠状態．
    proc_lib:hibernate(?MODULE, wake_hib, [Parent, Name, State, Mod, HibernateAfterTimeout, Debug]);

loop(Parent, Name, State, Mod, infinity, HibernateAfterTimeout, Debug) ->
  % 最も標準的な状態．メッセージを受け取るまで待機する．
    receive
        Msg ->
            decode_msg(Msg, Parent, Name, State, Mod, infinity, HibernateAfterTimeout, Debug, false)

    after HibernateAfterTimeout ->
      % 1回の待機が制限時間を超えた場合は休眠状態に入る．
        loop(Parent, Name, State, Mod, hibernate, HibernateAfterTimeout, Debug)
    end;

loop(Parent, Name, State, Mod, Time, HibernateAfterTimeout, Debug) ->
  % 次のメッセージの受信までの制限時間がある待機．
  % 受信しなかった場合は `timeout' というメッセージがきたものとして扱う．
    Msg =
        receive
            Input ->
                Input

        after Time ->
            timeout
        end,
    decode_msg(Msg, Parent, Name, State, Mod, Time, HibernateAfterTimeout, Debug, false).


% ****
% 受信したメッセージに対処する．システムによるメッセージや，リンクしていた親プロセスの終了はここで対応する．
% 通常のメッセージは `handle_msg' の方に引き継ぐ．
-spec decode_msg(
    Msg :: {'system', _, _}
         | {'EXIT', Parent :: pid(), Reason :: _}
         | 'timeout'
         | {'$gen_call', {pid(), reference()}, _}
         | {'$gen_cast', _}
         | _,
  % 第2-8引数は`loop' の引数と同じ
    Parent :: pid(),  % リンクされている場合は起動した親プロセスのPID，リンクされていない場合は自分自身のPID．
    Name   :: atom() | pid(),
    State  :: _,        % 状態
    Mod    :: module(), % `gen_server' コールバックモジュール
    Time   :: {'continue', _} | 'hibernate' | timeout(),
    HibernateAfterTimeout :: timeout(),
    Debug                 :: [sys:dbg_opt()],

    Hib :: boolean() % 休眠状態か否か？
) -> no_return().
decode_msg(Msg, Parent, Name, State, Mod, Time, HibernateAfterTimeout, Debug, Hib) ->
    case Msg of
        {system, From, Req} ->
            sys:handle_system_msg(Req, From, Parent, ?MODULE, Debug,
                [Name, State, Mod, Time, HibernateAfterTimeout], Hib);

        {'EXIT', Parent, Reason} ->
          % 自身がシステムプロセスで，かつリンクしていた親プロセスが死んだ場合．
            terminate(Reason, ?STACKTRACE(), Name, undefined, Msg, Mod, State, Debug);

        _Msg when Debug =:= [] ->
          % 最も標準的なメッセージの受信のハンドリング．
            handle_msg(Msg, Parent, Name, State, Mod, HibernateAfterTimeout);

        _Msg ->
            Debug1 = sys:handle_debug(Debug, fun print_event/3, Name, {in, Msg}),
            handle_msg(Msg, Parent, Name, State, Mod, HibernateAfterTimeout, Debug1)
    end.


% ****
% `gen_server:call' による同期的なリクエストに対してレスポンスを返す．
% 他の形式のメッセージは `handle_common_reply' に引き継ぐ．
% デバッグ情報なし版．
-spec handle_msg(
    Msg :: {'$gen_call', {pid(), reference()}, _} | {'$gen_cast', _} | 'timeout' | _,

  % 以下は `loop' の対応する引数と同じ．
    Parent :: pid(),
    Name   :: atom() | pid(),
    State  :: _,
    Mod    :: module(),
    HibernateAfterTimeout :: timeout()
) -> no_return().
handle_msg({'$gen_call', From, Msg}, Parent, Name, State, Mod, HibernateAfterTimeout) ->
  % `gen_server:call' による同期的なメッセージ送信の場合
    Result = try_handle_call(Mod, Msg, From, State),
      % ほぼ `{ok, Mod:handle_call(Msg, From, State)}' だが，例外処理などもやる．
    case Result of
        {ok, {reply, Reply, NState}} ->
            reply(From, Reply),
              % レスポンスを返す．
            loop(Parent, Name, NState, Mod, infinity, HibernateAfterTimeout, []);
              % メインループに戻る．

        {ok, {reply, Reply, NState, Time1}} ->
            reply(From, Reply),
            loop(Parent, Name, NState, Mod, Time1, HibernateAfterTimeout, []);

        {ok, {noreply, NState}} ->
            loop(Parent, Name, NState, Mod, infinity, HibernateAfterTimeout, []);

        {ok, {noreply, NState, Time1}} ->
            loop(Parent, Name, NState, Mod, Time1, HibernateAfterTimeout, []);

        {ok, {stop, Reason, Reply, NState}} ->
          % レスポンスを返してプロセスを終了する
            try
                terminate(Reason, ?STACKTRACE(), Name, From, Msg, Mod, NState, [])
            after
                reply(From, Reply)
            end;

        Other ->
            handle_common_reply(Other, Parent, Name, From, Msg, Mod, HibernateAfterTimeout, State)
    end;

handle_msg(Msg, Parent, Name, State, Mod, HibernateAfterTimeout) ->
  % `gen_server:call' によるもの以外のメッセージ．
    Reply = try_dispatch(Msg, Mod, State),
    handle_common_reply(Reply, Parent, Name, undefined, Msg, Mod, HibernateAfterTimeout, State).


% デバッグ情報つき版（`Debug' の引数をとるほか，`reply/5' の戻り値を使う）．
handle_msg({'$gen_call', From, Msg}, Parent, Name, State, Mod, HibernateAfterTimeout, Debug) ->
    Result = try_handle_call(Mod, Msg, From, State),
    case Result of
        {ok, {reply, Reply, NState}} ->
            Debug1 = reply(Name, From, Reply, NState, Debug),
            loop(Parent, Name, NState, Mod, infinity, HibernateAfterTimeout, Debug1);

        {ok, {reply, Reply, NState, Time1}} ->
            Debug1 = reply(Name, From, Reply, NState, Debug),
            loop(Parent, Name, NState, Mod, Time1, HibernateAfterTimeout, Debug1);

        {ok, {noreply, NState}} ->
            Debug1 = sys:handle_debug(Debug, fun print_event/3, Name, {noreply, NState}),
            loop(Parent, Name, NState, Mod, infinity, HibernateAfterTimeout, Debug1);

        {ok, {noreply, NState, Time1}} ->
            Debug1 = sys:handle_debug(Debug, fun print_event/3, Name, {noreply, NState}),
            loop(Parent, Name, NState, Mod, Time1, HibernateAfterTimeout, Debug1);

        {ok, {stop, Reason, Reply, NState}} ->
            try
                terminate(Reason, ?STACKTRACE(), Name, From, Msg, Mod, NState, Debug)
            after
                _ = reply(Name, From, Reply, NState, Debug)
            end;

        Other ->
            handle_common_reply(Other, Parent, Name, From, Msg, Mod, HibernateAfterTimeout, State, Debug)
    end;

handle_msg(Msg, Parent, Name, State, Mod, HibernateAfterTimeout, Debug) ->
    Reply = try_dispatch(Msg, Mod, State),
    handle_common_reply(Reply, Parent, Name, undefined, Msg, Mod, HibernateAfterTimeout, State, Debug).


% 同期的リクエストに対するレスポンスを送信する．失敗しても `ok' を戻り値とする．
-spec reply({pid(), reference()}, _) -> 'ok'.
reply({To, Tag}, Reply) ->
    catch To ! {Tag, Reply},
    ok.

% `reply/2' のデバッグ機能つき版．
-spec reply(
    Name  :: atom() | pid(),
    From  :: {pid(), reference()},
    Reply :: _,
    State :: _,
    Debug :: [sys:dbg_opt()]
) -> [sys:dbg_opt()].
reply(Name, From, Reply, State, Debug) ->
    reply(From, Reply),
    sys:handle_debug(Debug, fun print_event/3, Name, {out, Reply, From, State}).


% `handle_msg' で使われる．
% `Mod:handle_call' の呼び出しによりレスポンスを決定する．
try_handle_call(Mod, Msg, From, State) ->
    try
        {ok, Mod:handle_call(Msg, From, State)}
    catch
        throw:R            -> {ok, R};
        Class:R:Stacktrace -> {'EXIT', Class, R, Stacktrace}
    end.


% `gen_server:cast' による非同期的なリクエストと一般のメッセージとに対応する．
% 前者は `Mod:handle_cast'，後者は `Mod:handle_info' に適用する．
% `Mod:handle_info' はオプショナルなので存在しないこともあり，その場合はログに警告を残して何もしない．
-spec try_dispatch(
    Msg   :: {'$gen_cast', _} | 'timeout' | _,
    Mod   :: module(),  % `gen_server' コールバックモジュール
    State :: _
) -> {'ok', DispatchRet}
   | {'EXIT', Class :: 'error' | 'exit', Reason :; _, Stacktrace :: _}
when
    DispatchRet ::
        {noreply, NewState :: _}
      | {noreply, NewState :: _, timeout() | hibernate | {continue, _}}
      | {stop, Reason :: _, NewState :: _}.
try_dispatch({'$gen_cast', Msg}, Mod, State) -> try_dispatch(Mod, handle_cast, Msg, State);
try_dispatch(Info, Mod, State)               -> try_dispatch(Mod, handle_info, Info, State).

-spec try_dispatch(
    Mod   :: module(),
    Func  :: 'handle_cast' | 'handle_info',
    Msg   :: 'timeout' | (GeneralMsg :: _),
    State :: _
) -> {'ok', DispatchRet}
   | {'EXIT', Class :: 'error' | 'exit', Reason :: _, Stacktrace :: _}
when
    DispatchRet ::
        {noreply, NewState :: _}
      | {noreply, NewState :: _, timeout() | hibernate | {continue, _}}
      | {stop, Reason :: _, NewState :: _}.
try_dispatch(Mod, Func, Msg, State) ->
    try
        {ok, Mod:Func(Msg, State)}
    catch
        throw:R ->
            {ok, R};

        error:undef = R:Stacktrace when Func == handle_info ->
            case erlang:function_exported(Mod, handle_info, 2) of
                false ->
                    ?LOG_WARNING(
                       #{ label   => {gen_server, no_handle_info},
                          module  => Mod,
                          message => Msg },
                       #{ domain       => [otp],
                          report_cb    => fun gen_server:format_log/2,
                          error_logger =>
                             #{ tag       => warning_msg,
                                report_cb => fun gen_server:format_log/1 } }),
                    {ok, {noreply, State}};

                true ->
                    {'EXIT', error, R, Stacktrace}
            end;

        Class:R:Stacktrace ->
            {'EXIT', Class, R, Stacktrace}
    end.


% 例外のクラスを省略した場合は `exit' 扱い．
-spec terminate(_, _, _, _, _, _, _, _) -> no_return().
terminate(Reason, Stacktrace, Name, From, Msg, Mod, State, Debug) ->
  terminate(exit, Reason, Stacktrace, Reason, Name, From, Msg, Mod, State, Debug).

% `ReportReason' を省略した場合は `Reason' と `Stacktrace' からつくる．
-spec terminate(_, _, _, _, _, _, _, _, _) -> no_return().
terminate(Class, Reason, Stacktrace, Name, From, Msg, Mod, State, Debug) ->
  ReportReason = {Reason, Stacktrace},
  terminate(Class, Reason, Stacktrace, ReportReason, Name, From, Msg, Mod, State, Debug).

% 終了処理を行なう．
-spec terminate(
    Class        :: 'exit' | 'error',
    Reason       :: 'normal' | 'shutdown' | {'shutdown', _} | _,
    Stacktrace   :: _,
    ReportReason :: _,
    Name         :: atom() | pid(),
    From         :: pid(),
    Msg          :: _,
    Mod          :: module(),
    State        :: _,
    Debug        :: [sys:dbg_opt()]
) -> no_return().
terminate(Class, Reason, Stacktrace, ReportReason, Name, From, Msg, Mod, State, Debug) ->
    Reply = try_terminate(Mod, terminate_reason(Class, Reason, Stacktrace), State),
      % 基本的には `Mod:terminate' を呼び出すだけだが，例外処理もやる．
    case Reply of
        {'EXIT', C, R, S} ->
          % 終了処理中に `exit' または `error' の例外が生じた場合
            error_info({R, S}, Name, From, Msg, Mod, State, Debug),
            erlang:raise(C, R, S);
              % ログに残して終了．

        _ ->
          % 終了処理が正常に終わった場合
            case {Class, Reason} of
                {exit, normal}        -> ok;
                {exit, shutdown}      -> ok;
                {exit, {shutdown, _}} -> ok;
                _                     -> error_info(ReportReason, Name, From, Msg, Mod, State, Debug)
            end
              % そもそもの停止理由が異常終了の場合だけログに残す．
    end,
    case Stacktrace of
        [] -> erlang:Class(Reason);
        _  -> erlang:raise(Class, Reason, Stacktrace)
    end.


% `error' の場合はスタックトレースを終了理由につけ加える．
-spec terminate_reason(
    Class      :: 'exit' | 'error',
    Reason     :: _,
    Stacktrace :: _
) -> _.
terminate_reason(error, Reason, Stacktrace) -> {Reason, Stacktrace};
terminate_reason(exit, Reason, _Stacktrace) -> Reason.


% `Mod:terminate' を呼び出して終了処理を行なう．
% `Mod:terminate' はオプショナルなコールバック函数であり，ない場合は何もしない．
-spec try_terminate(
    Mod    :: module(),
    Reason :: _,
    State  :: _,
) -> {'ok', 'ok' | _} | {'EXIT', Class :: 'exit' | 'error', _, Stacktrace :: _}.
try_terminate(Mod, Reason, State) ->
    case erlang:function_exported(Mod, terminate, 2) of
        true ->
            try
                {ok, Mod:terminate(Reason, State)}
            catch
                throw:R            -> {ok, R};
                Class:R:Stacktrace -> {'EXIT', Class, R, Stacktrace}
           end;

        false ->
            {ok, ok}
    end.
