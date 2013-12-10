%%%----------------------------------------------------------------------
%%% File    : mod_shared_roster.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Shared roster management
%%% Created :  5 Mar 2005 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2013   ProcessOne
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

-module(mod_shared_roster).

-author('alexey@process-one.net').

-behaviour(gen_mod).

-export([start/2, stop/1, item_to_xml/1, export/1, import_info/0,
	 webadmin_menu/3, webadmin_page/3, get_user_roster/2,
	 get_subscription_lists/3, get_jid_info/4, import/5,
	 process_item/2, in_subscription/6, out_subscription/4,
	 user_available/1, unset_presence/4, register_user/2,
	 remove_user/2, list_groups/1, create_group/2,
	 create_group/3, delete_group/2, get_group_opts/2,
	 set_group_opts/3, get_group_users/2, import_start/2,
	 get_group_explicit_users/2, is_user_in_group/3,
	 add_user_to_group/3, remove_user_from_group/3]).

-export([command_group_create/5, command_group_delete/2,
         command_add_user/3, command_remove_user/3,
         command_list_users/2, command_list_groups/1]).

-include("ejabberd.hrl").
-include("logger.hrl").

-include("jlib.hrl").

-include("mod_roster.hrl").

-include("ejabberd_http.hrl").

-include("ejabberd_web_admin.hrl").

-include("ejabberd_commands.hrl").

-record(sr_group, {group_host = {<<"">>, <<"">>} :: {'$1' | binary(), '$2' | binary()},
                   opts = [] :: list() | '_' | '$2'}).

-record(sr_user, {us = {<<"">>, <<"">>} :: {binary(), binary()},
                  group_host = {<<"">>, <<"">>} :: {binary(), binary()}}).

start(Host, Opts) ->
    init_db(gen_mod:db_type(Opts)),
    ejabberd_hooks:add(webadmin_menu_host, Host, ?MODULE,
		       webadmin_menu, 70),
    ejabberd_hooks:add(webadmin_page_host, Host, ?MODULE,
		       webadmin_page, 50),
    ejabberd_hooks:add(roster_get, Host, ?MODULE,
		       get_user_roster, 70),
    ejabberd_hooks:add(roster_in_subscription, Host,
		       ?MODULE, in_subscription, 30),
    ejabberd_hooks:add(roster_out_subscription, Host,
		       ?MODULE, out_subscription, 30),
    ejabberd_hooks:add(roster_get_subscription_lists, Host,
		       ?MODULE, get_subscription_lists, 70),
    ejabberd_hooks:add(roster_get_jid_info, Host, ?MODULE,
		       get_jid_info, 70),
    ejabberd_hooks:add(roster_process_item, Host, ?MODULE,
		       process_item, 50),
    ejabberd_hooks:add(user_available_hook, Host, ?MODULE,
		       user_available, 50),
    ejabberd_hooks:add(unset_presence_hook, Host, ?MODULE,
		       unset_presence, 50),
    ejabberd_hooks:add(register_user, Host, ?MODULE,
		       register_user, 50),
    ejabberd_hooks:add(anonymous_purge_hook, Host, ?MODULE,
		       remove_user, 50),
    ejabberd_hooks:add(remove_user, Host, ?MODULE,
		       remove_user, 50),
    ejabberd_commands:register_commands(commands()).

init_db(mnesia) ->
    mnesia:create_table(sr_group,
                        [{disc_copies, [node()]},
                         {attributes, record_info(fields, sr_group)}]),
    mnesia:create_table(sr_user,
                        [{disc_copies, [node()]}, {type, bag},
                         {attributes, record_info(fields, sr_user)}]),
    update_tables(),
    mnesia:add_table_index(sr_user, group_host);
init_db(p1db) ->
    OptsFields = [Field || {Field, _} <- default_group_opts()],
    MapSize = ejabberd_config:get_option(
                p1db_mapsize,
                fun(I) when is_integer(I), I>0 -> I end,
                1024*1024*10),
    p1db:open_table(sr_group,
                    [{mapsize, MapSize},
                     {schema, [{keys, [host, group, server, user]},
                               {enc_key, fun enc_key/1},
                               {dec_key, fun dec_key/1}]}]),
    p1db:open_table(sr_opts,
                    [{mapsize, MapSize},
                     {schema, [{keys, [host, group]},
                               {vals, OptsFields},
                               {enc_key, fun enc_key/1},
                               {dec_key, fun dec_key/1},
                               {enc_val, fun enc_val/2},
                               {dec_val, fun dec_val/2}]}]),
    p1db:open_table(sr_user,
                    [{mapsize, MapSize},
                     {schema, [{keys, [host, server, user, group]},
                               {enc_key, fun enc_key/1},
                               {dec_key, fun dec_key/1}]}]);
init_db(_) ->
    ok.

stop(Host) ->
    ejabberd_hooks:delete(webadmin_menu_host, Host, ?MODULE,
			  webadmin_menu, 70),
    ejabberd_hooks:delete(webadmin_page_host, Host, ?MODULE,
			  webadmin_page, 50),
    ejabberd_hooks:delete(roster_get, Host, ?MODULE,
			  get_user_roster, 70),
    ejabberd_hooks:delete(roster_in_subscription, Host,
			  ?MODULE, in_subscription, 30),
    ejabberd_hooks:delete(roster_out_subscription, Host,
			  ?MODULE, out_subscription, 30),
    ejabberd_hooks:delete(roster_get_subscription_lists,
			  Host, ?MODULE, get_subscription_lists, 70),
    ejabberd_hooks:delete(roster_get_jid_info, Host,
			  ?MODULE, get_jid_info, 70),
    ejabberd_hooks:delete(roster_process_item, Host,
			  ?MODULE, process_item, 50),
    ejabberd_hooks:delete(user_available_hook, Host,
			  ?MODULE, user_available, 50),
    ejabberd_hooks:delete(unset_presence_hook, Host,
			  ?MODULE, unset_presence, 50),
    ejabberd_hooks:delete(register_user, Host, ?MODULE,
			  register_user, 50),
    ejabberd_hooks:delete(anonymous_purge_hook, Host,
			  ?MODULE, remove_user, 50),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE,
			  remove_user,
			  50),
    %%ejabberd_hooks:delete(remove_user, Host,
    %%    		  ?MODULE, remove_user, 50),
    ejabberd_commands:unregister_commands(commands()).

get_user_roster(Items, US) ->
    {U, S} = US,
    DisplayedGroups = get_user_displayed_groups(US),
    SRUsers = lists:foldl(fun (Group, Acc1) ->
				  GroupName = get_group_name(S, Group),
				  lists:foldl(fun (User, Acc2) ->
						      if User == US -> Acc2;
							 true ->
							     dict:append(User,
									 GroupName,
									 Acc2)
						      end
					      end,
					      Acc1, get_group_users(S, Group))
			  end,
			  dict:new(), DisplayedGroups),
    {NewItems1, SRUsersRest} = lists:mapfoldl(fun (Item,
						   SRUsers1) ->
						      {_, _, {U1, S1, _}} =
							  Item#roster.usj,
						      US1 = {U1, S1},
						      case dict:find(US1,
								     SRUsers1)
							  of
							{ok, _GroupNames} ->
							    {Item#roster{subscription
									     =
									     both,
									 ask =
									     none},
							     dict:erase(US1,
									SRUsers1)};
							error ->
							    {Item, SRUsers1}
						      end
					      end,
					      SRUsers, Items),
    ModVcard = get_vcard_module(S),
    SRItems = [#roster{usj = {U, S, {U1, S1, <<"">>}},
		       us = US, jid = {U1, S1, <<"">>},
		       name = get_rosteritem_name(ModVcard, U1, S1),
		       subscription = both, ask = none, groups = GroupNames}
	       || {{U1, S1}, GroupNames} <- dict:to_list(SRUsersRest)],
    SRItems ++ NewItems1.

get_vcard_module(Server) ->
    Modules = gen_mod:loaded_modules(Server),
    [M
     || M <- Modules,
	(M == mod_vcard) or (M == mod_vcard_ldap)].

get_rosteritem_name([], _, _) -> <<"">>;
get_rosteritem_name([ModVcard], U, S) ->
    From = jlib:make_jid(<<"">>, S, jlib:atom_to_binary(?MODULE)),
    To = jlib:make_jid(U, S, <<"">>),
    case lists:member(To#jid.lserver, ?MYHOSTS) of
        true ->
            IQ = {iq, <<"">>, get, <<"vcard-temp">>, <<"">>,
                  #xmlel{name = <<"vCard">>,
                         attrs = [{<<"xmlns">>, <<"vcard-temp">>}],
                         children = []}},
            IQ_Vcard = ModVcard:process_sm_iq(From, To, IQ),
            case catch get_rosteritem_name_vcard(IQ_Vcard#iq.sub_el) of
                {'EXIT', Err} ->
                    ?ERROR_MSG("Error found when trying to get the "
                               "vCard of ~s@~s in ~p:~n ~p",
                               [U, S, ModVcard, Err]),
                    <<"">>;
                NickName ->
                    NickName
            end;
        false ->
            <<"">>
    end.

get_rosteritem_name_vcard([]) -> <<"">>;
get_rosteritem_name_vcard([Vcard]) ->
    case xml:get_path_s(Vcard,
			[{elem, <<"NICKNAME">>}, cdata])
	of
      <<"">> ->
	  xml:get_path_s(Vcard, [{elem, <<"FN">>}, cdata]);
      Nickname -> Nickname
    end.

process_item(RosterItem, Host) ->
    USFrom = {UserFrom, ServerFrom} = RosterItem#roster.us,
    {UserTo, ServerTo, ResourceTo} = RosterItem#roster.jid,
    NameTo = RosterItem#roster.name,
    USTo = {UserTo, ServerTo},
    DisplayedGroups = get_user_displayed_groups(USFrom),
    CommonGroups = lists:filter(fun (Group) ->
					is_user_in_group(USTo, Group, Host)
				end,
				DisplayedGroups),
    case CommonGroups of
      [] -> RosterItem;
      %% Roster item cannot be removed: We simply reset the original groups:
      _ when RosterItem#roster.subscription == remove ->
	  GroupNames = lists:map(fun (Group) ->
					 get_group_name(Host, Group)
				 end,
				 CommonGroups),
	  RosterItem#roster{subscription = both, ask = none,
			    groups = GroupNames};
      %% Both users have at least a common shared group,
      %% So each user can see the other
      _ ->
	  case lists:subtract(RosterItem#roster.groups,
			      CommonGroups)
	      of
	    %% If it doesn't, then remove this user from any
	    %% existing roster groups.
	    [] ->
		mod_roster:out_subscription(UserTo, ServerTo,
					    jlib:make_jid(UserFrom, ServerFrom,
							  <<"">>),
					    unsubscribe),
		mod_roster:in_subscription(aaaa, UserFrom, ServerFrom,
					   jlib:make_jid(UserTo, ServerTo,
							 <<"">>),
					   unsubscribe, <<"">>),
		RosterItem#roster{subscription = both, ask = none};
	    %% If so, it means the user wants to add that contact
	    %% to his personal roster
	    PersonalGroups ->
		set_new_rosteritems(UserFrom, ServerFrom, UserTo,
				    ServerTo, ResourceTo, NameTo,
				    PersonalGroups)
	  end
    end.

build_roster_record(User1, Server1, User2, Server2,
		    Name2, Groups) ->
    USR2 = {User2, Server2, <<"">>},
    #roster{usj = {User1, Server1, USR2},
	    us = {User1, Server1}, jid = USR2, name = Name2,
	    subscription = both, ask = none, groups = Groups}.

set_new_rosteritems(UserFrom, ServerFrom, UserTo,
		    ServerTo, ResourceTo, NameTo, GroupsFrom) ->
    RIFrom = build_roster_record(UserFrom, ServerFrom,
				 UserTo, ServerTo, NameTo, GroupsFrom),
    set_item(UserFrom, ServerFrom, ResourceTo, RIFrom),
    JIDTo = jlib:make_jid(UserTo, ServerTo, <<"">>),
    JIDFrom = jlib:make_jid(UserFrom, ServerFrom, <<"">>),
    RITo = build_roster_record(UserTo, ServerTo, UserFrom,
			       ServerFrom, UserFrom, []),
    set_item(UserTo, ServerTo, <<"">>, RITo),
    mod_roster:out_subscription(UserFrom, ServerFrom, JIDTo,
				subscribe),
    mod_roster:in_subscription(aaa, UserTo, ServerTo,
			       JIDFrom, subscribe, <<"">>),
    mod_roster:out_subscription(UserTo, ServerTo, JIDFrom,
				subscribed),
    mod_roster:in_subscription(aaa, UserFrom, ServerFrom,
			       JIDTo, subscribed, <<"">>),
    mod_roster:out_subscription(UserTo, ServerTo, JIDFrom,
				subscribe),
    mod_roster:in_subscription(aaa, UserFrom, ServerFrom,
			       JIDTo, subscribe, <<"">>),
    mod_roster:out_subscription(UserFrom, ServerFrom, JIDTo,
				subscribed),
    mod_roster:in_subscription(aaa, UserTo, ServerTo,
			       JIDFrom, subscribed, <<"">>),
    RIFrom.

set_item(User, Server, Resource, Item) ->
    ResIQ = #iq{type = set, xmlns = ?NS_ROSTER,
		id = <<"push", (randoms:get_string())/binary>>,
		sub_el =
		    [#xmlel{name = <<"query">>,
			    attrs = [{<<"xmlns">>, ?NS_ROSTER}],
			    children = [mod_roster:item_to_xml(Item)]}]},
    ejabberd_router:route(jlib:make_jid(User, Server,
					Resource),
			  jlib:make_jid(<<"">>, Server, <<"">>),
			  jlib:iq_to_xml(ResIQ)).

get_subscription_lists({F, T, B}, User, Server) ->
    LUser = jlib:nodeprep(User),
    LServer = jlib:nameprep(Server),
    US = {LUser, LServer},
    DisplayedGroups = get_user_displayed_groups(US),
    SRUsers = lists:usort(lists:flatmap(fun (Group) ->
						get_group_users(LServer, Group)
					end,
					DisplayedGroups)),
    SRJIDs = [{U1, S1, <<"">>} || {U1, S1} <- SRUsers],
    {F, T, lists:usort(SRJIDs ++ B)}.

get_jid_info({Subscription, Groups}, User, Server,
	     JID) ->
    LUser = jlib:nodeprep(User),
    LServer = jlib:nameprep(Server),
    US = {LUser, LServer},
    {U1, S1, _} = jlib:jid_tolower(JID),
    US1 = {U1, S1},
    DisplayedGroups = get_user_displayed_groups(US),
    SRUsers = lists:foldl(fun (Group, Acc1) ->
				  lists:foldl(fun (User1, Acc2) ->
						      dict:append(User1,
								  get_group_name(LServer,
										 Group),
								  Acc2)
					      end,
					      Acc1,
					      get_group_users(LServer, Group))
			  end,
			  dict:new(), DisplayedGroups),
    case dict:find(US1, SRUsers) of
      {ok, GroupNames} ->
	  NewGroups = if Groups == [] -> GroupNames;
			 true -> Groups
		      end,
	  {both, NewGroups};
      error -> {Subscription, Groups}
    end.

in_subscription(Acc, User, Server, JID, Type,
		_Reason) ->
    process_subscription(in, User, Server, JID, Type, Acc).

out_subscription(UserFrom, ServerFrom, JIDTo,
		 unsubscribed) ->
    #jid{luser = UserTo, lserver = ServerTo} = JIDTo,
    JIDFrom = jlib:make_jid(UserFrom, ServerFrom, <<"">>),
    mod_roster:out_subscription(UserTo, ServerTo, JIDFrom,
				unsubscribe),
    mod_roster:in_subscription(aaaa, UserFrom, ServerFrom,
			       JIDTo, unsubscribe, <<"">>),
    process_subscription(out, UserFrom, ServerFrom, JIDTo,
			 unsubscribed, false);
out_subscription(User, Server, JID, Type) ->
    process_subscription(out, User, Server, JID, Type,
			 false).

process_subscription(Direction, User, Server, JID,
		     _Type, Acc) ->
    LUser = jlib:nodeprep(User),
    LServer = jlib:nameprep(Server),
    US = {LUser, LServer},
    {U1, S1, _} =
	jlib:jid_tolower(jlib:jid_remove_resource(JID)),
    US1 = {U1, S1},
    DisplayedGroups = get_user_displayed_groups(US),
    SRUsers = lists:usort(lists:flatmap(fun (Group) ->
						get_group_users(LServer, Group)
					end,
					DisplayedGroups)),
    case lists:member(US1, SRUsers) of
      true ->
	  case Direction of
	    in -> {stop, false};
	    out -> stop
	  end;
      false -> Acc
    end.

list_groups(Host) ->
    list_groups(Host, gen_mod:db_type(Host, ?MODULE)).

list_groups(Host, mnesia) ->
    mnesia:dirty_select(sr_group,
			[{#sr_group{group_host = {'$1', '$2'}, _ = '_'},
			  [{'==', '$2', Host}], ['$1']}]);
list_groups(Host, p1db) ->
    HPrefix = host_prefix(Host),
    case p1db:get_by_prefix(sr_opts, HPrefix) of
        {ok, L} ->
            lists:map(
              fun({Key, _Val, _VClock}) ->
                      get_suffix(HPrefix, Key)
              end, L);
        {error, _} ->
            []
    end;
list_groups(Host, riak) ->
    case ejabberd_riak:get_keys_by_index(sr_group, <<"host">>, Host) of
        {ok, Gs} ->
            [G || {G, _} <- Gs];
        _ ->
            []
    end;
list_groups(Host, odbc) ->
    case ejabberd_odbc:sql_query(Host,
				 [<<"select name from sr_group;">>])
	of
      {selected, [<<"name">>], Rs} -> [G || [G] <- Rs];
      _ -> []
    end.

groups_with_opts(Host) ->
    groups_with_opts(Host, gen_mod:db_type(Host, ?MODULE)).

groups_with_opts(Host, mnesia) ->
    Gs = mnesia:dirty_select(sr_group,
			     [{#sr_group{group_host = {'$1', Host}, opts = '$2',
					 _ = '_'},
			       [], [['$1', '$2']]}]),
    lists:map(fun ([G, O]) -> {G, O} end, Gs);
groups_with_opts(Host, p1db) ->
    HPrefix = host_prefix(Host),
    case p1db:get_by_prefix(sr_opts, HPrefix) of
        {ok, L} ->
            lists:map(
              fun({Key, Val, _VClock}) ->
                      Group = get_suffix(HPrefix, Key),
                      Opts = binary_to_term(Val),
                      {Group, Opts}
              end, L);
        {error, _} ->
            []
    end;
groups_with_opts(Host, riak) ->
    case ejabberd_riak:get_by_index(sr_group, <<"host">>, Host) of
        {ok, Rs} ->
            [{G, O} || #sr_group{group_host = {G, _}, opts = O} <- Rs];
        _ ->
            []
    end;
groups_with_opts(Host, odbc) ->
    case ejabberd_odbc:sql_query(Host,
				 [<<"select name, opts from sr_group;">>])
	of
      {selected, [<<"name">>, <<"opts">>], Rs} ->
	  [{G, opts_to_binary(ejabberd_odbc:decode_term(Opts))}
	   || [G, Opts] <- Rs];
      _ -> []
    end.

create_group(Host, Group) ->
    create_group(Host, Group, []).

create_group(Host, Group, Opts) ->
    create_group(Host, Group, Opts,
		 gen_mod:db_type(Host, ?MODULE)).

create_group(Host, Group, Opts, mnesia) ->
    R = #sr_group{group_host = {Group, Host}, opts = Opts},
    F = fun () -> mnesia:write(R) end,
    mnesia:transaction(F);
create_group(Host, Group, Opts, p1db) ->
    GHKey = gh2key(Group, Host),
    Val = term_to_binary(Opts),
    case p1db:insert(sr_opts, GHKey, Val) of
        ok -> {atomic, ok};
        {error, _} = Err -> {aborted, Err}
    end;
create_group(Host, Group, Opts, riak) ->
    {atomic, ejabberd_riak:put(#sr_group{group_host = {Group, Host},
                                         opts = Opts},
                               [{'2i', [{<<"host">>, Host}]}])};
create_group(Host, Group, Opts, odbc) ->
    SGroup = ejabberd_odbc:escape(Group),
    SOpts = ejabberd_odbc:encode_term(Opts),
    F = fun () ->
		odbc_queries:update_t(<<"sr_group">>,
				      [<<"name">>, <<"opts">>], [SGroup, SOpts],
				      [<<"name='">>, SGroup, <<"'">>])
	end,
    ejabberd_odbc:sql_transaction(Host, F).

delete_group(Host, Group) ->
    delete_group(Host, Group,
		 gen_mod:db_type(Host, ?MODULE)).

delete_group(Host, Group, mnesia) ->
    GroupHost = {Group, Host},
    F = fun () ->
		mnesia:delete({sr_group, GroupHost}),
		Users = mnesia:index_read(sr_user, GroupHost,
					  #sr_user.group_host),
		lists:foreach(fun (UserEntry) ->
				      mnesia:delete_object(UserEntry)
			      end,
			      Users)
	end,
    mnesia:transaction(F);
delete_group(Host, Group, p1db) ->
    GHKey = gh2key(Group, Host),
    GHPrefix = gh_prefix(Group, Host),
    DelRes = p1db:delete(sr_opts, GHKey),
    if DelRes == ok; DelRes == {error, notfound} ->
            try
                {ok, L1} = p1db:get_by_prefix(sr_group, GHPrefix),
                lists:foreach(
                  fun({Key, _, _}) ->
                          ok = p1db:async_delete(sr_group, Key)
                  end, L1),
                {ok, L2} = p1db:get(sr_user),
                lists:foreach(
                  fun({Key, _, _}) ->
                          case get_group_from_ushg(Key) of
                              Group ->
                                  ok = p1db:async_delete(sr_user, Key);
                              _ ->
                                  ok
                          end
                  end, L2),
                {atomic, ok}
            catch error:{badmatch, {error, _} = Err} ->
                    {aborted, Err}
            end;
       true ->
            {aborted, DelRes}
    end;
delete_group(Host, Group, riak) ->
    try
        ok = ejabberd_riak:delete(sr_group, {Group, Host}),
        ok = ejabberd_riak:delete_by_index(sr_user, <<"group_host">>,
                                           {Group, Host}),
        {atomic, ok}
    catch _:{badmatch, Err} ->
            {atomic, Err}
    end;
delete_group(Host, Group, odbc) ->
    SGroup = ejabberd_odbc:escape(Group),
    F = fun () ->
		ejabberd_odbc:sql_query_t([<<"delete from sr_group where name='">>,
					   SGroup, <<"';">>]),
		ejabberd_odbc:sql_query_t([<<"delete from sr_user where grp='">>,
					   SGroup, <<"';">>])
	end,
    ejabberd_odbc:sql_transaction(Host, F).

get_group_opts(Host, Group) ->
    get_group_opts(Host, Group,
		   gen_mod:db_type(Host, ?MODULE)).

get_group_opts(Host, Group, mnesia) ->
    case catch mnesia:dirty_read(sr_group, {Group, Host}) of
      [#sr_group{opts = Opts}] -> Opts;
      _ -> error
    end;
get_group_opts(Host, Group, p1db) ->
    GHKey = gh2key(Group, Host),
    case p1db:get(sr_opts, GHKey) of
        {ok, Val, _VClock} ->
            binary_to_term(Val);
        {error, _} ->
            error
    end;
get_group_opts(Host, Group, riak) ->
    case ejabberd_riak:get(sr_group, {Group, Host}) of
        {ok, #sr_group{opts = Opts}} -> Opts;
        _ -> error
    end;
get_group_opts(Host, Group, odbc) ->
    SGroup = ejabberd_odbc:escape(Group),
    case catch ejabberd_odbc:sql_query(Host,
				       [<<"select opts from sr_group where name='">>,
					SGroup, <<"';">>])
	of
      {selected, [<<"opts">>], [[SOpts]]} ->
	  opts_to_binary(ejabberd_odbc:decode_term(SOpts));
      _ -> error
    end.

set_group_opts(Host, Group, Opts) ->
    set_group_opts(Host, Group, Opts,
		   gen_mod:db_type(Host, ?MODULE)).

set_group_opts(Host, Group, Opts, mnesia) ->
    R = #sr_group{group_host = {Group, Host}, opts = Opts},
    F = fun () -> mnesia:write(R) end,
    mnesia:transaction(F);
set_group_opts(Host, Group, Opts, p1db) ->
    GHKey = gh2key(Group, Host),
    Val = term_to_binary(Opts),
    case p1db:insert(sr_opts, GHKey, Val) of
        ok -> {atomic, ok};
        {error, _} = Err -> {aborted, Err}
    end;
set_group_opts(Host, Group, Opts, riak) ->
    {atomic, ejabberd_riak:put(#sr_group{group_host = {Group, Host},
                                         opts = Opts},
                               [{'2i', [{<<"host">>, Host}]}])};
set_group_opts(Host, Group, Opts, odbc) ->
    SGroup = ejabberd_odbc:escape(Group),
    SOpts = ejabberd_odbc:encode_term(Opts),
    F = fun () ->
		odbc_queries:update_t(<<"sr_group">>,
				      [<<"name">>, <<"opts">>], [SGroup, SOpts],
				      [<<"name='">>, SGroup, <<"'">>])
	end,
    ejabberd_odbc:sql_transaction(Host, F).

get_user_groups(US) ->
    Host = element(2, US),
    DBType = gen_mod:db_type(Host, ?MODULE),
    get_user_groups(US, Host, DBType) ++
      get_special_users_groups(Host).

get_user_groups(US, Host, mnesia) ->
    case catch mnesia:dirty_read(sr_user, US) of
      Rs when is_list(Rs) ->
	  [Group
	   || #sr_user{group_host = {Group, H}} <- Rs, H == Host];
      _ -> []
    end;
get_user_groups(US, Host, p1db) ->
    USHPrefix = ush_prefix(US, Host),
    case p1db:get_by_prefix(sr_user, USHPrefix) of
        {ok, L} ->
            lists:map(
              fun({Key, _, _}) ->
                      get_suffix(USHPrefix, Key)
              end, L);
        {error, _} ->
            []
    end;
get_user_groups(US, Host, riak) ->
    case ejabberd_riak:get_by_index(sr_user, <<"us">>, US) of
        {ok, Rs} ->
            [Group || #sr_user{group_host = {Group, H}} <- Rs, H == Host];
        _ ->
            []
    end;
get_user_groups(US, Host, odbc) ->
    SJID = make_jid_s(US),
    case catch ejabberd_odbc:sql_query(Host,
				       [<<"select grp from sr_user where jid='">>,
					SJID, <<"';">>])
	of
      {selected, [<<"grp">>], Rs} -> [G || [G] <- Rs];
      _ -> []
    end.

is_group_enabled(Host1, Group1) ->
    {Host, Group} = split_grouphost(Host1, Group1),
    case get_group_opts(Host, Group) of
      error -> false;
      Opts -> is_group_enabled(Opts)
    end.

is_group_enabled(Opts) ->
    not proplists:get_bool(disabled, Opts).

get_group_opt(Opt, Opts, Default) ->
    case lists:keysearch(Opt, 1, Opts) of
        {value, {_, Val}} -> Val;
        false -> Default
    end.

get_online_users(Host) ->
    lists:usort([{U, S}
		 || {U, S, _} <- ejabberd_sm:get_vh_session_list(Host)]).

get_group_users(Host1, Group1) ->
    {Host, Group} = split_grouphost(Host1, Group1),
    Opts = get_group_opts(Host, Group),
    case get_group_opt(all_users, Opts, false) of
      true -> ejabberd_auth:get_vh_registered_users(Host);
      false -> []
    end
      ++
      case get_group_opt(online_users, Opts, false) of
	true -> get_online_users(Host);
	false -> []
      end
	++ get_group_explicit_users(Host, Group).

get_group_users(Host, Group, GroupOpts) ->
    case proplists:get_value(all_users, GroupOpts, false) of
      true -> ejabberd_auth:get_vh_registered_users(Host);
      false -> []
    end
      ++
      case proplists:get_value(online_users, GroupOpts, false)
	  of
	true -> get_online_users(Host);
	false -> []
      end
	++ get_group_explicit_users(Host, Group).

get_group_explicit_users(Host, Group) ->
    get_group_explicit_users(Host, Group,
			     gen_mod:db_type(Host, ?MODULE)).

get_group_explicit_users(Host, Group, mnesia) ->
    Read = (catch mnesia:dirty_index_read(sr_user,
					  {Group, Host}, #sr_user.group_host)),
    case Read of
      Rs when is_list(Rs) -> [R#sr_user.us || R <- Rs];
      _ -> []
    end;
get_group_explicit_users(Host, Group, p1db) ->
    GHPrefix = gh_prefix(Group, Host),
    case p1db:get_by_prefix(sr_group, GHPrefix) of
        {ok, L} ->
            lists:map(
              fun({Key, _, _}) ->
                      decode_us(get_suffix(GHPrefix, Key))
              end, L);
        {error, _} ->
            []
    end;
get_group_explicit_users(Host, Group, riak) ->
    case ejabberd_riak:get_by_index(sr_user, <<"group_host">>,
                                    {Group, Host}) of
        {ok, Rs} ->
            [R#sr_user.us || R <- Rs];
        _ ->
            []
    end;
get_group_explicit_users(Host, Group, odbc) ->
    SGroup = ejabberd_odbc:escape(Group),
    case catch ejabberd_odbc:sql_query(Host,
				       [<<"select jid from sr_user where grp='">>,
					SGroup, <<"';">>])
	of
      {selected, [<<"jid">>], Rs} ->
	  lists:map(fun ([JID]) ->
			    {U, S, _} =
				jlib:jid_tolower(jlib:string_to_jid(JID)),
			    {U, S}
		    end,
		    Rs);
      _ -> []
    end.

get_group_name(Host1, Group1) ->
    {Host, Group} = split_grouphost(Host1, Group1),
    Opts = get_group_opts(Host, Group),
    get_group_opt(name, Opts, Group).

get_special_users_groups(Host) ->
    lists:flatmap(fun ({Group, Opts}) ->
                          case get_group_opt(all_users, Opts, false) orelse
                              get_group_opt(online_users, Opts, false) of
                              true -> [Group];
                              false -> []
                          end
                  end,
                  groups_with_opts(Host)).

get_special_users_groups_online(Host) ->
    lists:flatmap(fun ({Group, Opts}) ->
                          case get_group_opt(online_users, Opts, false) of
                              true -> [Group];
                              false -> []
                          end
                  end,
                  groups_with_opts(Host)).

displayed_groups(GroupsOpts, SelectedGroupsOpts) ->
    DisplayedGroups = lists:usort(lists:flatmap(fun
						  ({_Group, Opts}) ->
						      [G
						       || G
							      <- proplists:get_value(displayed_groups,
										     Opts,
										     []),
                                                          is_group_enabled(Opts)]
						end,
						SelectedGroupsOpts)),
    [G
     || G <- DisplayedGroups,
        is_group_enabled(proplists:get_value(G, GroupsOpts, []))].

get_special_displayed_groups(GroupsOpts) ->
    Groups = lists:flatmap(
               fun({Group, Opts}) ->
                       case proplists:get_value(all_users, Opts, false) of
                           true -> [Group];
                           false -> []
                       end
               end,
               GroupsOpts),
    displayed_groups(GroupsOpts, Groups).

get_user_displayed_groups(LUser, LServer, GroupsOpts) ->
    Groups = get_user_displayed_groups(LUser, LServer,
				       GroupsOpts,
				       gen_mod:db_type(LServer, ?MODULE)),
    displayed_groups(GroupsOpts, Groups).

get_user_displayed_groups(LUser, LServer, GroupsOpts,
			  mnesia) ->
    case catch mnesia:dirty_read(sr_user, {LUser, LServer})
	of
      Rs when is_list(Rs) ->
	  [{Group, proplists:get_value(Group, GroupsOpts, [])}
	   || #sr_user{group_host = {Group, H}} <- Rs,
	      H == LServer];
      _ -> []
    end;
get_user_displayed_groups(LUser, LServer, GroupOpts, p1db) ->
    USHPrefix = ush_prefix({LUser, LServer}, LServer),
    case p1db:get_by_prefix(sr_user, USHPrefix) of
        {ok, L} ->
            lists:map(
              fun({Key, _, _}) ->
                      Group = get_suffix(USHPrefix, Key),
                      {Group, proplists:get_value(Group, GroupOpts, [])}
              end, L);
        {error, _} ->
            []
    end;
get_user_displayed_groups(LUser, LServer, GroupsOpts,
                          riak) ->
    case ejabberd_riak:get_by_index(sr_user,
                                    <<"us">>, {LUser, LServer}) of
        {ok, Rs} ->
            [{Group, proplists:get_value(Group, GroupsOpts, [])}
             || #sr_user{group_host = {Group, _}} <- Rs];
        _ ->
            []
    end;
get_user_displayed_groups(LUser, LServer, GroupsOpts,
			  odbc) ->
    SJID = make_jid_s(LUser, LServer),
    case catch ejabberd_odbc:sql_query(LServer,
				       [<<"select grp from sr_user where jid='">>,
					SJID, <<"';">>])
	of
      {selected, [<<"grp">>], Rs} ->
	  [{Group, proplists:get_value(Group, GroupsOpts, [])}
	   || [Group] <- Rs];
      _ -> []
    end.

get_user_displayed_groups(US) ->
    Host = element(2, US),
    DisplayedGroups1 =
        lists:usort(
          lists:flatmap(
            fun(Group) ->
                    Opts = get_group_opts(Host, Group),
                    case is_group_enabled(Opts) of
                        true ->
                            get_group_opt(displayed_groups, Opts, []);
                        false ->
                            []
                    end
            end,
            get_user_groups(US))),
    [Group || Group <- DisplayedGroups1, is_group_enabled(Host, Group)].

is_user_in_group(US, Group, Host) ->
    is_user_in_group(US, Group, Host,
		     gen_mod:db_type(Host, ?MODULE)).

is_user_in_group(US, Group, Host, mnesia) ->
    case catch mnesia:dirty_match_object(#sr_user{us = US,
						  group_host = {Group, Host}})
	of
      [] -> lists:member(US, get_group_users(Host, Group));
      _ -> true
    end;
is_user_in_group(US, Group, Host, p1db) ->
    USHGKey = ushg2key(US, Host, Group),
    case p1db:get(sr_user, USHGKey) of
        {ok, _, _} ->
            true;
        {error, _} ->
            lists:member(US, get_group_users(Host, Group))
    end;
is_user_in_group(US, Group, Host, riak) ->
    case ejabberd_riak:get_by_index(sr_user, <<"us">>, US) of
        {ok, Rs} ->
            case lists:any(
                   fun(#sr_user{group_host = {G, H}}) ->
                           (Group == G) and (Host == H)
                   end, Rs) of
                false ->
                    lists:member(US, get_group_users(Host, Group));
                true ->
                    true
            end;
        _Err ->
            false
    end;
is_user_in_group(US, Group, Host, odbc) ->
    SJID = make_jid_s(US),
    SGroup = ejabberd_odbc:escape(Group),
    case catch ejabberd_odbc:sql_query(Host,
				       [<<"select * from sr_user where jid='">>,
					SJID, <<"' and grp='">>, SGroup,
					<<"';">>])
	of
      {selected, _, []} ->
	  lists:member(US, get_group_users(Host, Group));
      _ -> true
    end.

add_user_to_group(Host, US, Group) ->
    {LUser, LServer} = US,
    case ejabberd_regexp:run(LUser, <<"^@.+@\$">>) of
      match ->
	  GroupOpts = (?MODULE):get_group_opts(Host, Group),
	  MoreGroupOpts = case LUser of
			    <<"@all@">> -> [{all_users, true}];
			    <<"@online@">> -> [{online_users, true}];
			    _ -> []
			  end,
	  (?MODULE):set_group_opts(Host, Group,
				   GroupOpts ++ MoreGroupOpts);
        nomatch ->
            Res = add_user_to_group(Host, US, Group,
                                    gen_mod:db_type(Host, ?MODULE)),
            push_user_to_displayed(LUser, LServer, Group, Host,
                                   both),
            push_displayed_to_user(LUser, LServer, Group, Host,
                                   both),
            Res
    end.

add_user_to_group(Host, US, Group, mnesia) ->
    R = #sr_user{us = US, group_host = {Group, Host}},
    F = fun () -> mnesia:write(R) end,
    mnesia:transaction(F);
add_user_to_group(Host, US, Group, p1db) ->
    GHUSKey = ghus2key(Group, Host, US),
    USHGKey = ushg2key(US, Host, Group),
    try
        ok = p1db:insert(sr_user, USHGKey, <<>>),
        ok = p1db:insert(sr_group, GHUSKey, <<>>),
        {atomic, ok}
    catch error:{badmatch, {error, _} = Err} ->
            {aborted, Err}
    end;
add_user_to_group(Host, US, Group, riak) ->
    {atomic, ejabberd_riak:put(
               #sr_user{us = US, group_host = {Group, Host}},
               [{i, {US, {Group, Host}}},
                {'2i', [{<<"us">>, US},
                        {<<"group_host">>, {Group, Host}}]}])};
add_user_to_group(Host, US, Group, odbc) ->
    SJID = make_jid_s(US),
    SGroup = ejabberd_odbc:escape(Group),
    F = fun () ->
		odbc_queries:update_t(<<"sr_user">>,
				      [<<"jid">>, <<"grp">>], [SJID, SGroup],
				      [<<"jid='">>, SJID, <<"' and grp='">>,
				       SGroup, <<"'">>])
	end,
    ejabberd_odbc:sql_transaction(Host, F).

push_displayed_to_user(LUser, LServer, Group, Host,
		       Subscription) ->
    GroupsOpts = groups_with_opts(LServer),
    GroupOpts = proplists:get_value(Group, GroupsOpts, []),
    DisplayedGroups = proplists:get_value(displayed_groups,
					  GroupOpts, []),
    [push_members_to_user(LUser, LServer, DGroup, Host,
			  Subscription)
     || DGroup <- DisplayedGroups].

remove_user_from_group(Host, US, Group) ->
    {LUser, LServer} = US,
    case ejabberd_regexp:run(LUser, <<"^@.+@\$">>) of
      match ->
	  GroupOpts = (?MODULE):get_group_opts(Host, Group),
	  NewGroupOpts = case LUser of
			   <<"@all@">> ->
			       lists:filter(fun (X) -> X /= {all_users, true}
					    end,
					    GroupOpts);
			   <<"@online@">> ->
			       lists:filter(fun (X) -> X /= {online_users, true}
					    end,
					    GroupOpts)
			 end,
	  (?MODULE):set_group_opts(Host, Group, NewGroupOpts);
      nomatch ->
	  Result = remove_user_from_group(Host, US, Group,
					  gen_mod:db_type(Host, ?MODULE)),
	  push_user_to_displayed(LUser, LServer, Group, Host,
				 remove),
	  push_displayed_to_user(LUser, LServer, Group, Host,
				 remove),
	  Result
    end.

remove_user_from_group(Host, US, Group, mnesia) ->
    R = #sr_user{us = US, group_host = {Group, Host}},
    F = fun () -> mnesia:delete_object(R) end,
    mnesia:transaction(F);
remove_user_from_group(Host, US, Group, p1db) ->
    GHUSKey = ghus2key(Group, Host, US),
    USHGKey = ushg2key(US, Host, Group),
    DelRes = p1db:delete(sr_user, USHGKey),
    if DelRes == ok; DelRes == {error, notfound} ->
            case p1db:delete(sr_group, GHUSKey) of
                ok -> {atomic, ok};
                {error, notfound} -> {atomic, ok};
                {error, _} = Err -> {aborted, Err}
            end;
       true ->
            {aborted, DelRes}
    end;
remove_user_from_group(Host, US, Group, riak) ->
    {atomic, ejabberd_riak:delete(sr_group, {US, {Group, Host}})};
remove_user_from_group(Host, US, Group, odbc) ->
    SJID = make_jid_s(US),
    SGroup = ejabberd_odbc:escape(Group),
    F = fun () ->
		ejabberd_odbc:sql_query_t([<<"delete from sr_user where jid='">>,
					   SJID, <<"' and grp='">>, SGroup,
					   <<"';">>]),
		ok
	end,
    ejabberd_odbc:sql_transaction(Host, F).

push_members_to_user(LUser, LServer, Group, Host,
		     Subscription) ->
    GroupsOpts = groups_with_opts(LServer),
    GroupOpts = proplists:get_value(Group, GroupsOpts, []),
    GroupName = proplists:get_value(name, GroupOpts, Group),
    Members = get_group_users(Host, Group),
    lists:foreach(fun ({U, S}) ->
			  push_roster_item(LUser, LServer, U, S, GroupName,
					   Subscription)
		  end,
		  Members).

register_user(User, Server) ->
    Groups = get_user_groups({User, Server}),
    [push_user_to_displayed(User, Server, Group, Server,
			    both)
     || Group <- Groups].

remove_user(User, Server) ->
    push_user_to_members(User, Server, remove).

push_user_to_members(User, Server, Subscription) ->
    LUser = jlib:nodeprep(User),
    LServer = jlib:nameprep(Server),
    GroupsOpts = groups_with_opts(LServer),
    SpecialGroups =
	get_special_displayed_groups(GroupsOpts),
    UserGroups = get_user_displayed_groups(LUser, LServer,
					   GroupsOpts),
    lists:foreach(fun (Group) ->
			  remove_user_from_group(LServer, {LUser, LServer},
						 Group),
			  GroupOpts = proplists:get_value(Group, GroupsOpts,
							  []),
			  GroupName = proplists:get_value(name, GroupOpts,
							  Group),
			  lists:foreach(fun ({U, S}) ->
						push_roster_item(U, S, LUser,
								 LServer,
								 GroupName,
								 Subscription)
					end,
					get_group_users(LServer, Group,
							GroupOpts))
		  end,
		  lists:usort(SpecialGroups ++ UserGroups)).

push_user_to_displayed(LUser, LServer, Group, Host,
		       Subscription) ->
    GroupsOpts = groups_with_opts(Host),
    GroupOpts = proplists:get_value(Group, GroupsOpts, []),
    GroupName = proplists:get_value(name, GroupOpts, Group),
    DisplayedToGroupsOpts = displayed_to_groups(Group, Host),
    Users =
        lists:usort(
          lists:append([get_group_users(Host, GroupD)
                        || {GroupD, _Opts} <- DisplayedToGroupsOpts])),
    UserGroups = get_user_groups({LUser, LServer}),
    [push_user_to_users(LUser, LServer, GroupD, Host,
			GroupName, Subscription, UserGroups, Users)
     || {GroupD, _Opts} <- DisplayedToGroupsOpts].

push_user_to_users(LUser, LServer, Group, _Host,
		   GroupName, Subscription, UserGroups, Users) ->
    lists:foreach(
      fun({U, S})
         when (U == LUser) and (S == LServer) ->
              ok;
         ({U, S} = US) ->
              case {Subscription, UserGroups} of
                  {remove, []} ->
                      push_roster_item(U, S, LUser, LServer, GroupName,
                                       Subscription);
                  {both, [Group]} ->
                      push_roster_item(U, S, LUser, LServer, GroupName,
                                       Subscription);
                  _ ->
                      UGroups = get_user_displayed_groups(US),
                      Groups =
                          lists:filter(
                            fun(G) ->
                                    lists:member(G, UGroups)
                            end, UserGroups),
                      Subscription1 =
                          case Groups of
                              [] -> remove;
                              _ -> both
                          end,
                      push_roster_item_with_groups(
                        U, S, LUser, LServer, Groups,
                        Subscription1)
              end
      end,
      Users).

displayed_to_groups(GroupName, LServer) ->
    GroupsOpts = groups_with_opts(LServer),
    lists:filter(fun ({_Group, Opts}) ->
			 lists:member(GroupName,
				      proplists:get_value(displayed_groups,
							  Opts, []))
		 end,
		 GroupsOpts).

push_item(User, Server, From, Item) ->
    ejabberd_sm:route(From,
		      jlib:make_jid(User, Server, <<"">>),
                      {broadcast, {item, Item#roster.jid,
				   Item#roster.subscription}}),
    Stanza = jlib:iq_to_xml(#iq{type = set,
				xmlns = ?NS_ROSTER,
				id = <<"push", (randoms:get_string())/binary>>,
				sub_el =
				    [#xmlel{name = <<"query">>,
					    attrs = [{<<"xmlns">>, ?NS_ROSTER}],
					    children = [item_to_xml(Item)]}]}),
    lists:foreach(fun (Resource) ->
			  JID = jlib:make_jid(User, Server, Resource),
			  ejabberd_router:route(JID, JID, Stanza)
		  end,
		  ejabberd_sm:get_user_resources(User, Server)).

push_roster_item(User, Server, ContactU, ContactS,
		 GroupName, Subscription) ->
    Item = #roster{usj =
		       {User, Server, {ContactU, ContactS, <<"">>}},
		   us = {User, Server}, jid = {ContactU, ContactS, <<"">>},
		   name = <<"">>, subscription = Subscription, ask = none,
		   groups = [GroupName]},
    push_item(User, Server,
	      jlib:make_jid(<<"">>, Server, <<"">>), Item).

push_roster_item_with_groups(User, Server, ContactU, ContactS,
                             Groups, Subscription) ->
    Item = #roster{usj =
		       {User, Server, {ContactU, ContactS, <<"">>}},
		   us = {User, Server}, jid = {ContactU, ContactS, <<"">>},
		   name = <<"">>, subscription = Subscription, ask = none,
		   groups = Groups},
    push_item(User, Server,
	      jlib:make_jid(<<"">>, Server, <<"">>), Item).

item_to_xml(Item) ->
    Attrs1 = [{<<"jid">>,
	       jlib:jid_to_string(Item#roster.jid)}],
    Attrs2 = case Item#roster.name of
	       <<"">> -> Attrs1;
	       Name -> [{<<"name">>, Name} | Attrs1]
	     end,
    Attrs3 = case Item#roster.subscription of
	       none -> [{<<"subscription">>, <<"none">>} | Attrs2];
	       from -> [{<<"subscription">>, <<"from">>} | Attrs2];
	       to -> [{<<"subscription">>, <<"to">>} | Attrs2];
	       both -> [{<<"subscription">>, <<"both">>} | Attrs2];
	       remove -> [{<<"subscription">>, <<"remove">>} | Attrs2]
	     end,
    Attrs4 = case ask_to_pending(Item#roster.ask) of
	       out -> [{<<"ask">>, <<"subscribe">>} | Attrs3];
	       both -> [{<<"ask">>, <<"subscribe">>} | Attrs3];
	       _ -> Attrs3
	     end,
    SubEls1 = lists:map(fun (G) ->
				#xmlel{name = <<"group">>, attrs = [],
				       children = [{xmlcdata, G}]}
			end,
			Item#roster.groups),
    SubEls = SubEls1 ++ Item#roster.xs,
    #xmlel{name = <<"item">>, attrs = Attrs4,
	   children = SubEls}.

ask_to_pending(subscribe) -> out;
ask_to_pending(unsubscribe) -> none;
ask_to_pending(Ask) -> Ask.

user_available(New) ->
    LUser = New#jid.luser,
    LServer = New#jid.lserver,
    Resources = ejabberd_sm:get_user_resources(LUser,
					       LServer),
    ?DEBUG("user_available for ~p @ ~p (~p resources)",
	   [LUser, LServer, length(Resources)]),
    case length(Resources) of
      %% first session for this user
      1 ->
	  OnlineGroups = get_special_users_groups_online(LServer),
	  lists:foreach(fun (OG) ->
				?DEBUG("user_available: pushing  ~p @ ~p grp ~p",
				       [LUser, LServer, OG]),
				push_user_to_displayed(LUser, LServer, OG,
						       LServer, both)
			end,
			OnlineGroups);
      _ -> ok
    end.

unset_presence(LUser, LServer, Resource, Status) ->
    Resources = ejabberd_sm:get_user_resources(LUser,
					       LServer),
    ?DEBUG("unset_presence for ~p @ ~p / ~p -> ~p "
	   "(~p resources)",
	   [LUser, LServer, Resource, Status, length(Resources)]),
    case length(Resources) of
      0 ->
	  OnlineGroups = get_special_users_groups_online(LServer),
	  lists:foreach(fun (OG) ->
				push_user_to_displayed(LUser, LServer, OG,
						       LServer, remove),
				push_displayed_to_user(LUser, LServer, OG,
						       LServer, remove)
			end,
			OnlineGroups);
      _ -> ok
    end.

%%---------------------
%% Web Admin
%%---------------------

webadmin_menu(Acc, _Host, Lang) ->
    [{<<"shared-roster">>, ?T(<<"Shared Roster Groups">>)}
     | Acc].

webadmin_page(_, Host,
	      #request{us = _US, path = [<<"shared-roster">>],
		       q = Query, lang = Lang} =
		  _Request) ->
    Res = list_shared_roster_groups(Host, Query, Lang),
    {stop, Res};
webadmin_page(_, Host,
	      #request{us = _US, path = [<<"shared-roster">>, Group],
		       q = Query, lang = Lang} =
		  _Request) ->
    Res = shared_roster_group(Host, Group, Query, Lang),
    {stop, Res};
webadmin_page(Acc, _, _) -> Acc.

list_shared_roster_groups(Host, Query, Lang) ->
    Res = list_sr_groups_parse_query(Host, Query),
    SRGroups = (?MODULE):list_groups(Host),
    FGroups = (?XAE(<<"table">>, [],
		    [?XE(<<"tbody">>,
			 (lists:map(fun (Group) ->
					    ?XE(<<"tr">>,
						[?XE(<<"td">>,
						     [?INPUT(<<"checkbox">>,
							     <<"selected">>,
							     Group)]),
						 ?XE(<<"td">>,
						     [?AC(<<Group/binary, "/">>,
							  Group)])])
				    end,
				    lists:sort(SRGroups))
			    ++
			    [?XE(<<"tr">>,
				 [?X(<<"td">>),
				  ?XE(<<"td">>,
				      [?INPUT(<<"text">>, <<"namenew">>,
					      <<"">>)]),
				  ?XE(<<"td">>,
				      [?INPUTT(<<"submit">>, <<"addnew">>,
					       <<"Add New">>)])])]))])),
    (?H1GL((?T(<<"Shared Roster Groups">>)),
	   <<"modsharedroster">>, <<"mod_shared_roster">>))
      ++
      case Res of
	ok -> [?XREST(<<"Submitted">>)];
	error -> [?XREST(<<"Bad format">>)];
	nothing -> []
      end
	++
	[?XAE(<<"form">>,
	      [{<<"action">>, <<"">>}, {<<"method">>, <<"post">>}],
	      [FGroups, ?BR,
	       ?INPUTT(<<"submit">>, <<"delete">>,
		       <<"Delete Selected">>)])].

list_sr_groups_parse_query(Host, Query) ->
    case lists:keysearch(<<"addnew">>, 1, Query) of
      {value, _} -> list_sr_groups_parse_addnew(Host, Query);
      _ ->
	  case lists:keysearch(<<"delete">>, 1, Query) of
	    {value, _} -> list_sr_groups_parse_delete(Host, Query);
	    _ -> nothing
	  end
    end.

list_sr_groups_parse_addnew(Host, Query) ->
    case lists:keysearch(<<"namenew">>, 1, Query) of
      {value, {_, Group}} when Group /= <<"">> ->
	  (?MODULE):create_group(Host, Group), ok;
      _ -> error
    end.

list_sr_groups_parse_delete(Host, Query) ->
    SRGroups = (?MODULE):list_groups(Host),
    lists:foreach(fun (Group) ->
			  case lists:member({<<"selected">>, Group}, Query) of
			    true -> (?MODULE):delete_group(Host, Group);
			    _ -> ok
			  end
		  end,
		  SRGroups),
    ok.

shared_roster_group(Host, Group, Query, Lang) ->
    Res = shared_roster_group_parse_query(Host, Group,
					  Query),
    GroupOpts = (?MODULE):get_group_opts(Host, Group),
    Name = get_opt(GroupOpts, name, <<"">>),
    Description = get_opt(GroupOpts, description, <<"">>),
    AllUsers = get_opt(GroupOpts, all_users, false),
    OnlineUsers = get_opt(GroupOpts, online_users, false),
    DisplayedGroups = get_opt(GroupOpts, displayed_groups,
			      []),
    Members = (?MODULE):get_group_explicit_users(Host,
						 Group),
    FMembers = iolist_to_binary(
                 [if AllUsers -> <<"@all@\n">>;
                     true -> <<"">>
                  end,
                  if OnlineUsers -> <<"@online@\n">>;
                     true -> <<"">>
                  end,
                  [[us_to_list(Member), $\n] || Member <- Members]]),
    FDisplayedGroups = [<<DG/binary, $\n>> || DG <- DisplayedGroups],
    DescNL = length(ejabberd_regexp:split(Description,
					   <<"\n">>)),
    FGroup = (?XAE(<<"table">>,
		   [{<<"class">>, <<"withtextareas">>}],
		   [?XE(<<"tbody">>,
			[?XE(<<"tr">>,
			     [?XCT(<<"td">>, <<"Name:">>),
			      ?XE(<<"td">>,
				  [?INPUT(<<"text">>, <<"name">>, Name)])]),
			 ?XE(<<"tr">>,
			     [?XCT(<<"td">>, <<"Description:">>),
			      ?XE(<<"td">>,
				  [?TEXTAREA(<<"description">>,
					     jlib:integer_to_binary(lists:max([3,
                                                                               DescNL])),
					     <<"20">>, Description)])]),
			 ?XE(<<"tr">>,
			     [?XCT(<<"td">>, <<"Members:">>),
			      ?XE(<<"td">>,
				  [?TEXTAREA(<<"members">>,
					     jlib:integer_to_binary(lists:max([3,
                                                                               byte_size(FMembers)])),
					     <<"20">>, FMembers)])]),
			 ?XE(<<"tr">>,
			     [?XCT(<<"td">>, <<"Displayed Groups:">>),
			      ?XE(<<"td">>,
				  [?TEXTAREA(<<"dispgroups">>,
					     jlib:integer_to_binary(lists:max([3,											        length(FDisplayedGroups)])),
					     <<"20">>,
					     list_to_binary(FDisplayedGroups))])])])])),
    (?H1GL((?T(<<"Shared Roster Groups">>)),
	   <<"modsharedroster">>, <<"mod_shared_roster">>))
      ++
      [?XC(<<"h2">>, <<(?T(<<"Group ">>))/binary, Group/binary>>)] ++
	case Res of
	  ok -> [?XREST(<<"Submitted">>)];
	  error -> [?XREST(<<"Bad format">>)];
	  nothing -> []
	end
	  ++
	  [?XAE(<<"form">>,
		[{<<"action">>, <<"">>}, {<<"method">>, <<"post">>}],
		[FGroup, ?BR,
		 ?INPUTT(<<"submit">>, <<"submit">>, <<"Submit">>)])].

shared_roster_group_parse_query(Host, Group, Query) ->
    case lists:keysearch(<<"submit">>, 1, Query) of
      {value, _} ->
	  {value, {_, Name}} = lists:keysearch(<<"name">>, 1,
					       Query),
	  {value, {_, Description}} =
	      lists:keysearch(<<"description">>, 1, Query),
	  {value, {_, SMembers}} = lists:keysearch(<<"members">>,
						   1, Query),
	  {value, {_, SDispGroups}} =
	      lists:keysearch(<<"dispgroups">>, 1, Query),
	  NameOpt = if Name == <<"">> -> [];
		       true -> [{name, Name}]
		    end,
	  DescriptionOpt = if Description == <<"">> -> [];
			      true -> [{description, Description}]
			   end,
	  DispGroups = str:tokens(SDispGroups, <<"\r\n">>),
	  DispGroupsOpt = if DispGroups == [] -> [];
			     true -> [{displayed_groups, DispGroups}]
			  end,
	  OldMembers = (?MODULE):get_group_explicit_users(Host,
							  Group),
	  SJIDs = str:tokens(SMembers, <<", \r\n">>),
	  NewMembers = lists:foldl(fun (_SJID, error) -> error;
				       (SJID, USs) ->
					   case SJID of
					     <<"@all@">> -> USs;
					     <<"@online@">> -> USs;
					     _ ->
						 case jlib:string_to_jid(SJID)
						     of
						   JID
						       when is_record(JID,
								      jid) ->
						       [{JID#jid.luser,
							 JID#jid.lserver}
							| USs];
						   error -> error
						 end
					   end
				   end,
				   [], SJIDs),
	  AllUsersOpt = case lists:member(<<"@all@">>, SJIDs) of
			  true -> [{all_users, true}];
			  false -> []
			end,
	  OnlineUsersOpt = case lists:member(<<"@online@">>,
					     SJIDs)
			       of
			     true -> [{online_users, true}];
			     false -> []
			   end,
	  (?MODULE):set_group_opts(Host, Group,
				   NameOpt ++
				     DispGroupsOpt ++
				       DescriptionOpt ++
					 AllUsersOpt ++ OnlineUsersOpt),
	  if NewMembers == error -> error;
	     true ->
		 AddedMembers = NewMembers -- OldMembers,
		 RemovedMembers = OldMembers -- NewMembers,
		 lists:foreach(fun (US) ->
				       (?MODULE):remove_user_from_group(Host,
									US,
									Group)
			       end,
			       RemovedMembers),
		 lists:foreach(fun (US) ->
				       (?MODULE):add_user_to_group(Host, US,
								   Group)
			       end,
			       AddedMembers),
		 ok
	  end;
      _ -> nothing
    end.

get_opt(Opts, Opt, Default) ->
    case lists:keysearch(Opt, 1, Opts) of
      {value, {_, Val}} -> Val;
      false -> Default
    end.

us_to_list({User, Server}) ->
    jlib:jid_to_string({User, Server, <<"">>}).

split_grouphost(Host, Group) ->
    case str:tokens(Group, <<"@">>) of
      [GroupName, HostName] -> {HostName, GroupName};
      [_] -> {Host, Group}
    end.

make_jid_s(U, S) ->
    ejabberd_odbc:escape(jlib:jid_to_string(jlib:jid_tolower(jlib:make_jid(U,
									   S,
									   <<"">>)))).

make_jid_s({U, S}) -> make_jid_s(U, S).

opts_to_binary(Opts) ->
    lists:map(
      fun({name, Name}) ->
              {name, iolist_to_binary(Name)};
         ({description, Desc}) ->
              {description, iolist_to_binary(Desc)};
         ({displayed_groups, Gs}) ->
              {displayed_groups, [iolist_to_binary(G) || G <- Gs]};
         (Opt) ->
              Opt
      end, Opts).

host_prefix(Host) ->
    <<Host/binary, 0>>.

get_suffix(Prefix, Key) ->
    Size = size(Prefix),
    <<_:Size/binary, Suffix/binary>> = Key,
    Suffix.

gh2key(Group, Host) ->
    <<Host/binary, 0, Group/binary>>.

ghus2key(Group, Host, {User, Server}) ->
    <<Host/binary, 0, Group/binary, 0, Server/binary, 0, User/binary>>.

ushg2key({User, Server}, Host, Group) ->
    <<Host/binary, 0, Server/binary, 0, User/binary, 0, Group/binary>>.

gh_prefix(Group, Host) ->
    <<Host/binary, 0, Group/binary, 0>>.

ush_prefix({User, Server}, Host) ->
    <<Host/binary, 0, Server/binary, 0, User/binary, 0>>.

get_group_from_ushg(Key) ->
    [Group|_] = lists:reverse(binary:split(Key, <<0>>, [global])),
    Group.

decode_us(Bin) ->
    [Server, User] = binary:split(Bin, <<0>>, [global]),
    {User, Server}.

enc_key(L) ->
    str:join(L, 0).

dec_key(Key) ->
    binary:split(Key, <<0>>, [global]).

default_group_opts() ->
    [{name, <<"">>},
     {description, <<"">>},
     {displayed_groups, []},
     {all_users, false},
     {online_users, false},
     {disabled, false}].

enc_val(_, Vals) ->
    Opts = lists:map(
             fun({{Key, _}, BinVal}) ->
                     Val = if Key == name; Key == description ->
                                   BinVal;
                              Key == all_users; Key == online_users;
                              Key == disabled ->
                                   jlib:binary_to_atom(BinVal);
                              true ->
                                   jlib:expr_to_term(BinVal)
                           end,
                     {Key, Val}
             end, lists:zip(default_group_opts(), Vals)),
    term_to_binary(Opts).

dec_val(_, Bin) ->
    Opts = binary_to_term(Bin),
    lists:map(
      fun({Key, DefVal}) ->
              Val = case lists:keyfind(Key, 1, Opts) of
                        {_, V} -> V;
                        false -> DefVal
                    end,
              if is_binary(Val) -> Val;
                 is_atom(Val) -> jlib:atom_to_binary(Val);
                 true -> jlib:term_to_expr(Val)
              end
      end, default_group_opts()).

update_tables() ->
    update_sr_group_table(),
    update_sr_user_table().

update_sr_group_table() ->
    Fields = record_info(fields, sr_group),
    case mnesia:table_info(sr_group, attributes) of
        Fields ->
            ejabberd_config:convert_table_to_binary(
              sr_group, Fields, set,
              fun(#sr_group{group_host = {G, _}}) -> G end,
              fun(#sr_group{group_host = {G, H},
                            opts = Opts} = R) ->
                      R#sr_group{group_host = {iolist_to_binary(G),
                                               iolist_to_binary(H)},
                                 opts = opts_to_binary(Opts)}
              end);
        _ ->
            ?INFO_MSG("Recreating sr_group table", []),
            mnesia:transform_table(sr_group, ignore, Fields)
    end.

update_sr_user_table() ->
    Fields = record_info(fields, sr_user),
    case mnesia:table_info(sr_user, attributes) of
        Fields ->
            ejabberd_config:convert_table_to_binary(
              sr_user, Fields, bag,
              fun(#sr_user{us = {U, _}}) -> U end,
              fun(#sr_user{us = {U, S}, group_host = {G, H}} = R) ->
                      R#sr_user{us = {iolist_to_binary(U), iolist_to_binary(S)},
                                group_host = {iolist_to_binary(G),
                                              iolist_to_binary(H)}}
              end);
        _ ->
            ?INFO_MSG("Recreating sr_user table", []),
            mnesia:transform_table(sr_user, ignore, Fields)
    end.

export(_Server) ->
    [{sr_group,
      fun(Host, #sr_group{group_host = {Group, LServer}, opts = Opts})
            when LServer == Host ->
              SGroup = ejabberd_odbc:escape(Group),
              SOpts = ejabberd_odbc:encode_term(Opts),
              [[<<"delete from sr_group where name='">>, Group, <<"';">>],
               [<<"insert into sr_group(name, opts) values ('">>,
                SGroup, <<"', '">>, SOpts, <<"');">>]];
         (_Host, _R) ->
              []
      end},
     {sr_user,
      fun(Host, #sr_user{us = {U, S}, group_host = {Group, LServer}})
            when LServer == Host ->
              SGroup = ejabberd_odbc:escape(Group),
              SJID = ejabberd_odbc:escape(
                       jlib:jid_to_string(
                         jlib:jid_tolower(
                           jlib:make_jid(U, S, <<"">>)))),
              [[<<"delete from sr_user where jid='">>, SJID,
                <<"'and grp='">>, Group, <<"';">>],
               [<<"insert into sr_user(jid, grp) values ('">>,
                SJID, <<"', '">>, SGroup, <<"');">>]];
         (_Host, _R) ->
              []
      end}].

import_info() ->
    [{<<"sr_group">>, 3}, {<<"sr_user">>, 3}].

import_start(_LServer, DBType) ->
    init_db(DBType).

import(LServer, {odbc, _}, mnesia, <<"sr_group">>,
       [Group, SOpts, _TimeStamp]) ->
    G = #sr_group{group_host = {Group, LServer},
                  opts = ejabberd_odbc:decode_term(SOpts)},
    mnesia:dirty_write(G);
import(LServer, {odbc, _}, mnesia, <<"sr_user">>,
       [SJID, Group, _TimeStamp]) ->
    #jid{luser = U, lserver = S} = jlib:string_to_jid(SJID),
    User = #sr_user{us = {U, S}, group_host = {Group, LServer}},
    mnesia:dirty_write(User);
import(LServer, {odbc, _}, riak, <<"sr_group">>,
       [Group, SOpts, _TimeStamp]) ->
    G = #sr_group{group_host = {Group, LServer},
                  opts = ejabberd_odbc:decode_term(SOpts)},
    ejabberd_riak:put(G, [{'2i', [{<<"host">>, LServer}]}]);
import(LServer, {odbc, _}, riak, <<"sr_user">>, [SJID, Group|_]) ->
    #jid{luser = U, lserver = S} = jlib:string_to_jid(SJID),
    User = #sr_user{us = {U, S}, group_host = {Group, LServer}},
    ejabberd_riak:put(User,
                      [{i, {{U, S}, {Group, LServer}}},
                       {'2i', [{<<"us">>, {U, S}},
                               {<<"group_host">>, {Group, LServer}}]}]);
import(LServer, {odbc, _}, p1db, <<"sr_group">>,
       [Group, SOpts, _TimeStamp]) ->
    Opts = ejabberd_odbc:decode_term(SOpts),
    GHKey = gh2key(Group, LServer),
    Val = term_to_binary(Opts),
    p1db:async_insert(sr_opts, GHKey, Val);
import(LServer, {odbc, _}, p1db, <<"sr_user">>,
       [SJID, Group, _TimeStamp]) ->
    #jid{luser = U, lserver = S} = jlib:string_to_jid(SJID),
    US = {U, S},
    GHUSKey = ghus2key(Group, LServer, US),
    USHGKey = ushg2key(US, LServer, Group),
    p1db:async_insert(sr_group, GHUSKey, <<>>),
    p1db:async_insert(sr_user, USHGKey, <<>>);
import(_, {odbc, _}, odbc, _Tab, _) ->
    ok.

commands() ->
    [
     #ejabberd_commands{name = shared_group_create,
                        tags = [erlang],
                        desc = "Create new shared roster group",
                        module = ?MODULE,
                        function = command_group_create,
                        args = [{host, binary}, {groupid, binary},
                                {name, binary}, {description, binary},
                                {displayed_groups, {list, {group, binary}}}],
                        result = {res, restuple}},
     #ejabberd_commands{name = shared_group_delete,
                        tags = [erlang],
                        desc = "Delete existing shared roster group",
                        module = ?MODULE,
                        function = command_group_delete,
                        args = [{host, binary}, {groupid, binary}],
                        result = {res, restuple}},
     #ejabberd_commands{name = shared_group_add_user,
                        tags = [erlang],
                        desc = "Add user to existing shared roster group",
                        module = ?MODULE,
                        function = command_add_user,
                        args = [{host, binary}, {groupid, binary}, {user, binary}],
                        result = {res, restuple}},
     #ejabberd_commands{name = shared_group_remove_user,
                        tags = [erlang],
                        desc = "Remove user from existing shared roster group",
                        module = ?MODULE,
                        function = command_remove_user,
                        args = [{host, binary}, {groupid, binary}, {user, binary}],
                        result = {res, restuple}},
     #ejabberd_commands{name = shared_group_list_users,
                        tags = [erlang],
                        desc = "List users in shared roster group",
                        module = ?MODULE,
                        function = command_list_users,
                        args = [{host, binary}, {groupid, binary}],
                        result = {res, {tuple, [
                                                {res, restuple},
                                                {users, {list, {user, string}}}]}}},
     #ejabberd_commands{name = shared_group_list,
                        tags = [erlang],
                        desc = "List all register shared roster groups",
                        module = ?MODULE,
                        function = command_list_groups,
                        args = [{host, binary}],
                        result = {res, {tuple, [
                                                {res, restuple},
                                                {groups, {list, {group, string}}}]}}}
].

code_to_restuple({atomic, _}) ->
    {ok, ""};
code_to_restuple({_, Res}) when is_binary(Res) ->
    {false, binary_to_list(Res)};
code_to_restuple({_, Res}) ->
    {false, lists:flatten(io_lib:format("~p", [Res]))}.

command_group_create(Host, Id, Name, Description, DisplayedGroups) ->
    Opts = [{name, Name},
            {displayed_groups, DisplayedGroups},
            {description, Description}],
    code_to_restuple(mod_shared_roster:create_group(Host, Id, Opts)).

command_group_delete(Host, Id) ->
    code_to_restuple(mod_shared_roster:delete_group(Host, Id)).

command_add_user(Host, Id, User) ->
    Jid = jlib:string_to_jid(User),
    case Jid of
        error ->
            {error, "Invalid JID"};
        #jid{user=Node, server=Domain} ->
            code_to_restuple(mod_shared_roster:add_user_to_group(Host, {Node, Domain}, Id))
    end.

command_remove_user(Host, Id, User) ->
    Jid = jlib:string_to_jid(User),
    case Jid of
        error ->
            {error, "Invalid JID"};
        #jid{user=Node, server=Domain} ->
            code_to_restuple(mod_shared_roster:remove_user_from_group(Host, {Node, Domain}, Id))
    end.

command_list_users(Host, Id) ->
    Users = mod_shared_roster:get_group_explicit_users(Host, Id),
    Jids = lists:map(fun({User, Server}) ->
                             jlib:jid_to_string(jlib:make_jid(User, Server, <<"">>))
                     end, Users),
    {{ok, ""}, Jids}.

command_list_groups(Host) ->
    Groups = mod_shared_roster:list_groups(Host),
    {{ok, ""}, Groups}.
