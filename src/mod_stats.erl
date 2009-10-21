%%%----------------------------------------------------------------------
%%% File    : mod_stats.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Basic statistics.
%%% Created : 11 Jan 2003 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2009   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%
%%%----------------------------------------------------------------------

-module(mod_stats).
-author('alexey@process-one.net').

-behaviour(gen_mod).

-export([start/2,
	 stop/1,
	 process_local_iq/3]).

-include_lib("exmpp/include/exmpp.hrl").

start(Host, Opts) ->
    IQDisc = gen_mod:get_opt(iqdisc, Opts, one_queue),
    gen_iq_handler:add_iq_handler(ejabberd_local, list_to_binary(Host), ?NS_STATS_s,
				  ?MODULE, process_local_iq, IQDisc).

stop(Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, list_to_binary(Host), ?NS_STATS_s).


process_local_iq(_From, To, #iq{type = get,
				ns = XMLNS, payload = SubEl} = IQ_Rec) ->
    Node = string:tokens(exmpp_xml:get_attribute_as_list(SubEl, 'node', ""), "/"),
    Names = get_names(exmpp_xml:get_child_elements(SubEl), []),

    case get_local_stats(exmpp_jid:domain(To), Node, Names) of
	{result, Res} ->
	    Result = #xmlel{ns = XMLNS, name = 'query', children = Res},
	    exmpp_iq:result(IQ_Rec, Result);
	{error, Error} ->
	    exmpp_iq:error(IQ_Rec, Error)
    end;
process_local_iq(_From, _To, #iq{type = set} = IQ_Rec) ->
    exmpp_iq:error(IQ_Rec, 'not-allowed').


get_names([], Res) ->
    Res;
get_names([#xmlel{name = "stat", attrs = Attrs} | Els], Res) ->
    Name = exmpp_xml:get_attribute_from_list_as_binary(Attrs, 'name', <<>>),
    case Name of
	<<>> ->
	    get_names(Els, Res);
	_ ->
	    get_names(Els, [Name | Res])
    end;
get_names([_ | Els], Res) ->
    get_names(Els, Res).


-define(STAT(Name), #xmlel{ns = ?NS_STATS_s, name = 'stat', attrs = [?XMLATTR('name', Name)]}).

get_local_stats(_Server, [], []) ->
    {result,
     [?STAT(<<"users/online">>),
      ?STAT(<<"users/total">>),
      ?STAT(<<"users/all-hosts/online">>),
      ?STAT(<<"users/all-hosts/total">>)
     ]};

get_local_stats(Server, [], Names) ->
    {result, lists:map(fun(Name) ->
			       get_local_stat(Server, [], Name)
		       end, Names)};

get_local_stats(_Server, ["running nodes", _], []) ->
    {result,
     [?STAT(<<"time/uptime">>),
      ?STAT(<<"time/cputime">>),
      ?STAT(<<"users/online">>),
      ?STAT(<<"transactions/committed">>),
      ?STAT(<<"transactions/aborted">>),
      ?STAT(<<"transactions/restarted">>),
      ?STAT(<<"transactions/logged">>)
     ]};

get_local_stats(_Server, ["running nodes", ENode], Names) ->
    case search_running_node(ENode) of
	false ->
	    {error, 'item-not-found'};
	Node ->
	    {result,
	     lists:map(fun(Name) -> get_node_stat(Node, Name) end, Names)}
    end;

get_local_stats(_Server, _, _) ->
    {error, 'feature-not-implemented'}.



-define(STATVAL(Val, Unit),
	#xmlel{ns = ?NS_STATS_s, name = 'stat', attrs =
	 [?XMLATTR('name', Name),
	  ?XMLATTR('units', Unit),
	  ?XMLATTR('value', Val)
	 ]}).

-define(STATERR(Code, Desc),
	#xmlel{ns = ?NS_STATS_s, name = 'stat', attrs=
	 [?XMLATTR('name', Name)], children =
	 [#xmlel{ns = ?NS_STATS_s, name = 'error', attrs =
	   [?XMLATTR('code', Code)], children =
	   [#xmlcdata{cdata = Desc}]}]}).


get_local_stat(Server, [], Name) when Name == <<"users/online">> ->
    case catch ejabberd_sm:get_vh_session_list(Server) of
	{'EXIT', _Reason} ->
	    ?STATERR(<<"500">>, <<"Internal Server Error">>);
	Users ->
	    ?STATVAL(list_to_binary(integer_to_list(length(Users))), <<"users">>)
    end;

get_local_stat(Server, [], Name) when Name == <<"users/total">> ->
    %%LServer = jlib:nameprep(Server),
    case catch ejabberd_auth:get_vh_registered_users_number(binary_to_list(Server)) of
	{'EXIT', _Reason} ->
	    ?STATERR(<<"500">>, <<"Internal Server Error">>);
	NUsers ->
	    ?STATVAL(list_to_binary(integer_to_list(NUsers)), <<"users">>)
    end;

get_local_stat(_Server, [], Name) when Name == <<"users/all-hosts/online">> ->
    case catch mnesia:table_info(session, size) of
	{'EXIT', _Reason} ->
	    ?STATERR(<<"500">>, <<"Internal Server Error">>);
	Users ->
	    ?STATVAL(list_to_binary(integer_to_list(Users)), <<"users">>)
    end;

get_local_stat(_Server, [], Name) when Name == <<"users/all-hosts/total">> ->
    case catch mnesia:table_info(passwd, size) of
	{'EXIT', _Reason} ->
	    ?STATERR(<<"500">>, <<"Internal Server Error">>);
	Users ->
	    ?STATVAL(list_to_binary(integer_to_list(Users)), <<"users">>)
    end;

get_local_stat(_Server, _, Name) ->
    ?STATERR(<<"404">>, <<"Not Found">>).



get_node_stat(Node, Name) when Name == <<"time/uptime">> ->
    case catch rpc:call(Node, erlang, statistics, [wall_clock]) of
	{badrpc, _Reason} ->
	    ?STATERR(<<"500">>, <<"Internal Server Error">>);
	CPUTime ->
	    ?STATVAL(list_to_binary(
	       io_lib:format("~.3f", [element(1, CPUTime)/1000])), "seconds")
    end;

get_node_stat(Node, Name) when Name == <<"time/cputime">> ->
    case catch rpc:call(Node, erlang, statistics, [runtime]) of
	{badrpc, _Reason} ->
	    ?STATERR(<<"500">>, <<"Internal Server Error">>);
	RunTime ->
	    ?STATVAL(list_to_binary(
	       io_lib:format("~.3f", [element(1, RunTime)/1000])), "seconds")
    end;

get_node_stat(Node, Name) when Name == <<"users/online">> ->
    case catch rpc:call(Node, ejabberd_sm, dirty_get_my_sessions_list, []) of
	{badrpc, _Reason} ->
	    ?STATERR(<<"500">>, <<"Internal Server Error">>);
	Users ->
	    ?STATVAL(list_to_binary(integer_to_list(length(Users))), <<"users">>)
    end;

get_node_stat(Node, Name) when Name == <<"transactions/committed">> ->
    case catch rpc:call(Node, mnesia, system_info, [transaction_commits]) of
	{badrpc, _Reason} ->
	    ?STATERR(<<"500">>, <<"Internal Server Error">>);
	Transactions ->
	    ?STATVAL(list_to_binary(integer_to_list(Transactions)), <<"transactions">>)
    end;

get_node_stat(Node, Name) when Name == <<"transactions/aborted">> ->
    case catch rpc:call(Node, mnesia, system_info, [transaction_failures]) of
	{badrpc, _Reason} ->
	    ?STATERR(<<"500">>, <<"Internal Server Error">>);
	Transactions ->
	    ?STATVAL(list_to_binary(integer_to_list(Transactions)), <<"transactions">>)
    end;

get_node_stat(Node, Name) when Name == <<"transactions/restarted">> ->
    case catch rpc:call(Node, mnesia, system_info, [transaction_restarts]) of
	{badrpc, _Reason} ->
	    ?STATERR(<<"500">>, <<"Internal Server Error">>);
	Transactions ->
	    ?STATVAL(list_to_binary(integer_to_list(Transactions)), <<"transactions">>)
    end;

get_node_stat(Node, Name) when Name == <<"transactions/logged">> ->
    case catch rpc:call(Node, mnesia, system_info, [transaction_log_writes]) of
	{badrpc, _Reason} ->
	    ?STATERR(<<"500">>, <<"Internal Server Error">>);
	Transactions ->
	    ?STATVAL(list_to_binary(integer_to_list(Transactions)), <<"transactions">>)
    end;

get_node_stat(_, Name) ->
    ?STATERR(<<"404">>, <<"Not Found">>).


search_running_node(SNode) ->
    search_running_node(SNode, mnesia:system_info(running_db_nodes)).

search_running_node(_, []) ->
    false;
search_running_node(SNode, [Node | Nodes]) ->
    case atom_to_list(Node) of
	SNode ->
	    Node;
	_ ->
	    search_running_node(SNode, Nodes)
    end.

