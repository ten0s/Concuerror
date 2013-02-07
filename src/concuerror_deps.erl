%%%----------------------------------------------------------------------
%%% Copyright (c) 2012, Alkis Gotovos <el3ctrologos@hotmail.com>,
%%%                     Maria Christakis <mchrista@softlab.ntua.gr>
%%%                 and Kostis Sagonas <kostis@cs.ntua.gr>.
%%% All rights reserved.
%%%
%%% This file is distributed under the Simplified BSD License.
%%% Details can be found in the LICENSE file.
%%%----------------------------------------------------------------------
%%% Authors     : Stavros Aronis <aronisstav@gmail.com>
%%% Description : Dependency relation for Erlang
%%%----------------------------------------------------------------------

-module(concuerror_deps).

-export([may_have_dependencies/1,
         dependent/2,
         lock_release_atom/0]).

-spec may_have_dependencies(concuerror_sched:transition()) -> boolean().

may_have_dependencies({_Lid, {error, _}, []}) -> false;
may_have_dependencies({_Lid, {Spawn, _}, []})
  when Spawn =:= spawn; Spawn =:= spawn_link; Spawn =:= spawn_monitor;
       Spawn =:= spawn_opt -> false;
may_have_dependencies({_Lid, {'receive', {unblocked, _, _}}, []}) -> false;
may_have_dependencies({_Lid, exited, []}) -> false;
may_have_dependencies(_Else) -> true.

-spec lock_release_atom() -> '_._concuerror_lock_release'.

lock_release_atom() -> '_._concuerror_lock_release'.

-define( ONLY_INITIALLY, true).
-define(      SYMMETRIC, true).
-define(      CHECK_MSG, true).
-define(     ALLOW_SWAP, true).
-define(DONT_ALLOW_SWAP, false).
-define( DONT_CHECK_MSG, false).

-spec dependent(concuerror_sched:transition(),
                concuerror_sched:transition()) -> boolean().

dependent(A, B) ->
    dependent(A, B, ?CHECK_MSG, ?ALLOW_SWAP).

%% Instructions from the same process are always dependent
dependent({Lid, _Instr1, _Msgs1},
          {Lid, _Instr2, _Msgs2}, ?ONLY_INITIALLY, ?ONLY_INITIALLY) ->
    true;

%% XXX: This should be fixed in sched:recent_dependency_cv and removed
dependent({_Lid1, _Instr1, _Msgs1},
          {_Lid2, Special, _Msgs2}, ?ONLY_INITIALLY, ?ONLY_INITIALLY)
  when Special =:= 'block'; Special =:= 'init' ->
    false;

%% Register and unregister have the same dependencies.
%% Use a unique value for the Pid to avoid checks there.
dependent({Lid, {unregister, RegName}, Msgs}, B,
          ?ONLY_INITIALLY, ?ONLY_INITIALLY) ->
    dependent({Lid, {register, {RegName, make_ref()}}, Msgs}, B,
              ?ONLY_INITIALLY, ?ONLY_INITIALLY);
dependent(A, {Lid, {unregister, RegName}, Msgs},
          ?ONLY_INITIALLY, ?ONLY_INITIALLY) ->
    dependent(A, {Lid, {register, {RegName, make_ref()}}, Msgs},
              ?ONLY_INITIALLY, ?ONLY_INITIALLY);


%% Decisions depending on send and receive statements:

%% Sending to the same process:
dependent({_Lid1, Instr1, PreMsgs1} = Trans1,
          {_Lid2, Instr2, PreMsgs2} = Trans2,
          ?CHECK_MSG, ?ONLY_INITIALLY) ->
    Check =
        case {PreMsgs1, Instr1, PreMsgs2, Instr2} of
            {[_|_], _, [_|_], _} ->
                {PreMsgs1, PreMsgs2};
            {[_|_], _, [], {send, {_RegName, Lid, Msg}}} ->
                {PreMsgs1, [{Lid, [Msg]}]};
            {[], {send, {_RegName, Lid, Msg}}, [_|_], _} ->
                {[{Lid, [Msg]}], PreMsgs2};
            _ -> false
        end,
    case Check of
        false -> dependent(Trans1, Trans2, ?DONT_CHECK_MSG, ?ONLY_INITIALLY);
        {Msgs1, Msgs2} ->
            Lids1 = ordsets:from_list(orddict:fetch_keys(Msgs1)),
            Lids2 = ordsets:from_list(orddict:fetch_keys(Msgs2)),
            case ordsets:intersection(Lids1, Lids2) of
                [] ->
                    dependent(Trans1, Trans2, ?DONT_CHECK_MSG, ?ONLY_INITIALLY);
                [Key] ->
                    %% XXX: Can be refined
                    case {orddict:fetch(Key, Msgs1), orddict:fetch(Key, Msgs2)} of
                        {[V1], [V2]} ->
                            LockReleaseAtom = lock_release_atom(),
                            V1 =/= LockReleaseAtom andalso V2 =/= LockReleaseAtom;
                        _Else -> true
                    end;
                _ -> true %% XXX: Can be refined
            end
    end;

%% Sending to an activated after clause depends on that receive's patterns OR
%% Sending the message that triggered a receive's 'had_after'
dependent({ Lid1,         Instr1, PreMsgs1} = Trans1,
          { Lid2, {Tag, Info},   _Msgs2} = Trans2,
          CheckMsg, AllowSwap) when
      Tag =:= 'after';
      (Tag =:= 'receive' andalso
       element(1, Info) =:= had_after andalso
       element(2, Info) =:= Lid1) ->
    Check =
        case {PreMsgs1, Instr1} of
            {[_|_], _} -> {ok, PreMsgs1};
            {[], {send, {_RegName, Lid, Msg}}} -> {ok, [{Lid, [Msg]}]};
            _ -> false
        end,
    Dependent =
        case Check of
            false -> false;
            {ok, Msgs1} ->
                case orddict:find(Lid2, Msgs1) of
                    {ok, MsgsToLid2} ->
                        Fun =
                            case Tag of
                                'after' -> Info;
                                'receive' ->
                                    Target = element(3, Info),
                                    fun(X) -> X =:= Target end
                            end,
                        lists:any(Fun, MsgsToLid2);
                    error -> false
                end
        end,
    case Dependent of
        true -> true;
        false ->
            case AllowSwap of
                true -> dependent(Trans2, Trans1, CheckMsg, ?DONT_ALLOW_SWAP);
                false -> false
            end
    end;


%% ETS operations live in their own small world.
dependent({_Lid1, {ets, Op1}, _Msgs1},
          {_Lid2, {ets, Op2}, _Msgs2},
          _CheckMsg, ?SYMMETRIC) ->
    dependent_ets(Op1, Op2);

%% Registering a table with the same name as an existing one.
dependent({_Lid1, { ets, {   new,           [_Table, Name, Options]}}, _Msgs1},
          {_Lid2, {exit, {normal, {{_Heirs, Tables}, _Name, _Links}}}, _Msgs2},
          _CheckMsg, _AllowSwap) ->
    NamedTables = [N || {_Lid, {ok, N}} <- Tables],
    lists:member(named_table, Options) andalso
        lists:member(Name, NamedTables);

%% Table owners exits mess things up.
dependent({_Lid1, { ets, {   _Op,                     [Table|_Rest]}}, _Msgs1},
          {_Lid2, {exit, {normal, {{_Heirs, Tables}, _Name, _Links}}}, _Msgs2},
          _CheckMsg, _AllowSwap) ->
    lists:keymember(Table, 1, Tables);

%% Heirs exit should also be monitored.
%% Links exit should be monitored to be sure that messages are captured.
dependent({Lid1, {exit, {normal, {{Heirs1, _Tbls1}, _Name1, Links1}}}, _Msgs1},
          {Lid2, {exit, {normal, {{Heirs2, _Tbls2}, _Name2, Links2}}}, _Msgs2},
          _CheckMsg, ?SYMMETRIC) ->
    lists:member(Lid1, Heirs2) orelse lists:member(Lid2, Heirs1) orelse
        lists:member(Lid1, Links2) orelse lists:member(Lid2, Links1);


%% Registered processes:

%% Sending using name to a process that may exit and unregister.
dependent({_Lid1, {send,                     {TName, _TLid, _Msg}}, _Msgs1},
          {_Lid2, {exit, {normal, {_Tables, {ok, TName}, _Links}}}, _Msgs2},
          _CheckMsg, _AllowSwap) ->
    true;

%% Send using name before process has registered itself (or after ungeristering).
dependent({_Lid1, {register,      {RegName, _TLid}}, _Msgs1},
          {_Lid2, {    send, {RegName, _Lid, _Msg}}, _Msgs2},
          _CheckMsg, _AllowSwap) ->
    true;

%% Two registers using the same name or the same process.
dependent({_Lid1, {register, {RegName1, TLid1}}, _Msgs1},
          {_Lid2, {register, {RegName2, TLid2}}, _Msgs2},
          _CheckMsg, ?SYMMETRIC) ->
    RegName1 =:= RegName2 orelse TLid1 =:= TLid2;

%% Register a process that may exit.
dependent({_Lid1, {register, {_RegName, TLid}}, _Msgs1},
          { TLid, {    exit,  {normal, _Info}}, _Msgs2},
          _CheckMsg, _AllowSwap) ->
    true;

%% Register for a name that might be in use.
dependent({_Lid1, {register,                           {Name, _TLid}}, _Msgs1},
          {_Lid2, {    exit, {normal, {_Tables, {ok, Name}, _Links}}}, _Msgs2},
          _CheckMsg, _AllowSwap) ->
    true;

%% Whereis using name before process has registered itself.
dependent({_Lid1, {register, {RegName, _TLid1}}, _Msgs1},
          {_Lid2, { whereis, {RegName, _TLid2}}, _Msgs2},
          _CheckMsg, _AllowSwap) ->
    true;

%% Process alive and exits
dependent({_Lid1, {is_process_alive,            TLid}, _Msgs1},
          { TLid, {            exit, {normal, _Info}}, _Msgs2},
          _CheckMsg, _AllowSwap) ->
    true;

%% Process registered and exits
dependent({_Lid1, {whereis,                          {Name, _TLid1}}, _Msgs1},
          {_Lid2, {   exit, {normal, {_Tables, {ok, Name}, _Links}}}, _Msgs2},
          _CheckMsg, _AllowSwap) ->
    true;

%% Monitor/Demonitor and exit.
dependent({_Lid, {Linker,            TLid}, _Msgs1},
          {TLid, {  exit, {normal, _Info}}, _Msgs2},
          _CheckMsg, _AllowSwap)
  when Linker =:= demonitor; Linker =:= link; Linker =:= unlink ->
    true;

dependent({_Lid, {monitor, {TLid, _MonRef}}, _Msgs1},
          {TLid, {   exit, {normal, _Info}}, _Msgs2},
          _CheckMsg, _AllowSwap) ->
    true;

%% Trap exits flag and linked process exiting.
dependent({Lid1, {process_flag,        {trap_exit, _Value, Links1}}, _Msgs1},
          {Lid2, {        exit, {normal, {_Tables, _Name, Links2}}}, _Msgs2},
          _CheckMsg, _AllowSwap) ->
    lists:member(Lid2, Links1) orelse lists:member(Lid1, Links2);

%% Swap the two arguments if the test is not symmetric by itself.
dependent(TransitionA, TransitionB, CheckMsg, ?ALLOW_SWAP) ->
    case independent(TransitionA, TransitionB) of
        true -> false;
        maybe ->
            dependent(TransitionB, TransitionA, CheckMsg, ?DONT_ALLOW_SWAP)
    end;
dependent(TransitionA, TransitionB, _CheckMsg, ?DONT_ALLOW_SWAP) ->
    case independent(TransitionA, TransitionB) of
        true -> false;
        maybe -> false %% This should be changed to true.
    end.

-spec independent(concuerror_sched:transition(),
                  concuerror_sched:transition()) -> 'true' | 'maybe'.

independent({_Lid1, {_Op1, _}, _Msgs1}, {_Lid2, {_Op2, _}, _Msgs2}) ->
    maybe.

%% ETS table dependencies:

dependent_ets(Op1, Op2) ->
    dependent_ets(Op1, Op2, ?ALLOW_SWAP).

dependent_ets({insert, [T, _, Keys1, KP, Objects1, true]},
              {insert, [T, _, Keys2, KP, Objects2, true]}, ?SYMMETRIC) ->
    case ordsets:intersection(Keys1, Keys2) of
        [] -> false;
        Keys ->
            Fold =
                fun(_K, true) -> true;
                   (K, false) ->
                        lists:keyfind(K, KP, Objects1) =/=
                            lists:keyfind(K, KP, Objects2)
                end,
            lists:foldl(Fold, false, Keys)
    end;
dependent_ets({insert_new, [_, _, _, _, _, false]},
              {insert_new, [_, _, _, _, _, false]}, ?SYMMETRIC) ->
    false;
dependent_ets({insert_new, [T, _, Keys1, KP, _Objects1, _Status1]},
              {insert_new, [T, _, Keys2, KP, _Objects2, _Status2]},
              ?SYMMETRIC) ->
    ordsets:intersection(Keys1, Keys2) =/= [];
dependent_ets({insert_new, [T, _, Keys1, KP, _Objects1, _Status1]},
              {insert, [T, _, Keys2, KP, _Objects2, true]}, _AllowSwap) ->
    ordsets:intersection(Keys1, Keys2) =/= [];
dependent_ets({Insert, [T, _, Keys, _KP, _Objects1, true]},
              {lookup, [T, _, K]}, _AllowSwap)
  when Insert =:= insert; Insert =:= insert_new ->
    ordsets:is_element(K, Keys);
dependent_ets({delete, [T, _]}, {_, [T|_]}, _AllowSwap) ->
    true;
dependent_ets({new, [_Tid1, Name, Options1]},
              {new, [_Tid2, Name, Options2]}, ?SYMMETRIC) ->
    lists:member(named_table, Options1) andalso
        lists:member(named_table, Options2);
dependent_ets(Op1, Op2, ?ALLOW_SWAP) ->
    case independent_ets(Op1, Op2) of
        true -> false;
        maybe -> dependent_ets(Op2, Op1, ?DONT_ALLOW_SWAP)
    end;
dependent_ets(Op1, Op2, ?DONT_ALLOW_SWAP) ->
    case independent_ets(Op1, Op2) of
        true -> false;
        maybe -> false %% This should be changed to true.
    end.

-spec independent_ets(term(), term()) -> 'true' | 'maybe'.

independent_ets({_Tag1, _}, {_Tag2, _}) ->
    maybe.
