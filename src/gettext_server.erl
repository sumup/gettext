%% -*- coding: latin-1 -*-
%% -------------------------------------------------------------------------
%% Permission is hereby granted, free of charge, to any person obtaining a
%% copy of this software and associated documentation files (the
%% "Software"), to deal in the Software without restriction, including
%% without limitation the rights to use, copy, modify, merge, publish,
%% distribute, sublicense, and/or sell copies of the Software, and to permit
%% persons to whom the Software is furnished to do so, subject to the
%% following conditions:
%%
%% The above copyright notice and this permission notice shall be included
%% in all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
%% OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
%% MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN
%% NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
%% DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
%% OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE
%% USE OR OTHER DEALINGS IN THE SOFTWARE.
%%
%% @copyright 2003 Torbj�rn T�rnkvist
%% @author Torbj�rn T�rnkvist <tobbe@tornkvist.org>
%% @doc Server for Erlang gettext.

-module(gettext_server).

-behaviour(gen_server).

%%--------------------------------------------------------------------
%% Include files
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% External exports
-export([start_link/0, start_link/1, start_link/2,
         start/0, start/1, start/2]).

%% Standard callback functions to make this module work as an
%% initialization callback for itself.
-export([gettext_dir/0, gettext_def_lang/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("gettext_internal.hrl").

-define(elog(X,Y), error_logger:info_msg("*elog ~p:~p: " X,
					[?MODULE, ?LINE | Y])).

-define(SERVER, ?MODULE).
-define(KEY(Lang,Key), {Key,Lang}).  % note reverse order
-define(ENTRY(Lang, Key, Val), {?KEY(Lang,Key), Val}).


-record(state, {
          cache = [],        % list_of( #cache{} )
          def_lang,          % default language
          gettext_dir,       % Dir where all the data are stored
          table_name         % autogenerated from server name
	 }).

%%%
%%% Hold info about the languages stored.
%%%
-record(cache, {
          language  = ?DEFAULT_LANG,
          charset   = ?DEFAULT_CHARSET
	 }).

%%====================================================================
%% External functions
%%====================================================================

%% Callback functions for default initialization.
gettext_dir() ->
    case code:priv_dir(gettext) of
        {error, bad_name} -> "./priv";
        Dir -> Dir
    end.

gettext_def_lang() ->
    ?DEFAULT_LANG.


%%--------------------------------------------------------------------
%% Function: start_link/0
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link() ->
    start_link({?MODULE, application:get_all_env()}, ?SERVER).

start_link(CallBackMod) when is_atom(CallBackMod) ->
    start_link({CallBackMod, application:get_all_env()}, ?SERVER);
start_link(Config) when is_list(Config) ->
    start_link({?MODULE, Config}, ?SERVER);
start_link({CallBackMod, Config}) ->
    start_link({CallBackMod, Config}, ?SERVER).

start_link({CallBackMod, Config}, Name) ->
    gen_server:start_link({local, Name}, ?MODULE, [{CallBackMod, Config}, Name], []).

%%--------------------------------------------------------------------

start() ->
    start({?MODULE, application:get_all_env()}, ?SERVER).

start(CallBackMod) when is_atom(CallBackMod) ->
    start({CallBackMod, application:get_all_env()}, ?SERVER);
start(Config) when is_list(Config) ->
    start({?MODULE, Config}, ?SERVER);
start({CallBackMod, Config}) ->
    start({CallBackMod, Config}, ?SERVER).

start({CallBackMod, Config}, Name) ->
    gen_server:start({local, Name}, ?MODULE, [{CallBackMod, Config}, Name], []).

%%====================================================================
%% Server functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init/1
%% Description: Initiates the server
%% Returns: {ok, State}          |
%%          {ok, State, Timeout} |
%%          ignore               |
%%          {stop, Reason}
%%--------------------------------------------------------------------
init([CallBackModConfig, Name]) ->
	{CallBackMod0, Config} = CallBackModConfig,
    CallBackMod = case os:getenv(?ENV_CBMOD) of
                      false -> CallBackMod0;
                      CbMod -> list_to_atom(CbMod)
                  end,
    GettextDir = get_gettext_dir(CallBackMod, Config),
    DefLang = get_default_lang(CallBackMod, Config),
    TableNameStr = atom_to_list(Name) ++ "_db",
    TableName = list_to_atom(TableNameStr),
    Cache = create_db(TableName, GettextDir),
    {ok, #state{cache       = Cache,
		gettext_dir = GettextDir,
		def_lang    = DefLang,
		table_name  = TableName
               }}.


%%--------------------------------------------------------------------
%% Function: handle_call/3
%% Description: Handling call messages
%% Returns: {reply, Reply, State}          |
%%          {reply, Reply, State, Timeout} |
%%          {noreply, State}               |
%%          {noreply, State, Timeout}      |
%%          {stop, Reason, Reply, State}   | (terminate/2 is called)
%%          {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------
handle_call({key2str, Key, Lang}, _From, State) ->
    TableName = State#state.table_name,
	DefaultLang = State#state.def_lang,
    Reply = lookup(TableName, Lang, DefaultLang, Key),
    {reply, Reply, State};
%%
handle_call({lang2cset, Lang}, _From, State) ->
    Reply = case lists:keysearch(Lang, #cache.language, State#state.cache) of
		false      -> {error, "not found"};
		{value, C} -> {ok, C#cache.charset}
	    end,
    {reply, Reply, State};
%%
handle_call({store_pofile, Lang, File}, _From, State) ->
    GettextDir = State#state.gettext_dir,
    TableName  = State#state.table_name,
    case store_pofile(TableName, Lang, File, GettextDir, State#state.cache) of
	{ok, NewCache} ->
	    {reply, ok, State#state{cache = NewCache}};
	Else ->
	    {reply, Else, State}
    end;
%%
handle_call(all_lcs, _From, State) ->
    {reply, [X#cache.language || X <- State#state.cache], State};
%%
handle_call({reload_custom_lang, Lang}, _From, State) ->
    GettextDir = State#state.gettext_dir,
    TableName  = State#state.table_name,
    {reply, reload_custom_lang(TableName, GettextDir, Lang), State};
%%
handle_call({unload_custom_lang, Lang}, _From, State) ->
    GettextDir = State#state.gettext_dir,
    TableName  = State#state.table_name,
    {reply, unload_custom_lang(TableName, GettextDir, Lang), State};
%%
handle_call(recreate_db, _From, State) ->
    Cache = recreate_db(State#state.table_name, State#state.gettext_dir),
    {reply, ok, State#state{cache = Cache}};
%%
handle_call(gettext_dir, _From, State) ->
    {reply, State#state.gettext_dir, State};
%%
handle_call({change_gettext_dir, Dir}, _From, State) ->
    Cache = recreate_db(State#state.table_name, Dir),
    {reply, ok, State#state{gettext_dir = Dir, cache = Cache}};
%%
handle_call(default_lang, _From, State) ->
    {reply, State#state.def_lang, State};
%%
handle_call(recreate_ets, _From, State) ->
    recreate_ets_table(State#state.table_name),
    {reply, ok, State};
%%
handle_call(stop, _, State) ->
    {stop, normal, stopped, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast/2
%% Description: Handling cast messages
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info/2
%% Description: Handling all non call/cast messages
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate/2
%% Description: Shutdown the server
%% Returns: any (ignored by gen_server)
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Func: code_change/3
%% Purpose: Convert process state when code is changed
%% Returns: {ok, NewState}
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

get_gettext_dir(CallBackMod, Config) ->
	case proplists:get_value(gettext_dir, Config) of
		undefined -> get_gettext_dir(CallBackMod);
		ConfDir -> ConfDir
	end.

get_gettext_dir(CallBackMod) ->
    case gettext_compile:get_env(path) of
      "." ->
        try CallBackMod:gettext_dir()
        catch
        _:_ -> "." % fallback
        end;
      Dir -> Dir
    end.

get_default_lang(CallBackMod, Config) ->
	case proplists:get_value(default_lang, Config) of
		undefined -> get_default_lang(CallBackMod);
		ConfLang -> ConfLang
	end.

get_default_lang(CallBackMod) ->
    case gettext_compile:get_env(lang) of
      ?DEFAULT_LANG ->
        case catch CallBackMod:gettext_def_lang() of
          Dir when is_list(Dir) -> Dir;
          _ -> ?DEFAULT_LANG % fallback
        end;
      DefLang -> DefLang
    end.

db_filename(TableName, GettextDir) ->
    filename:join(GettextDir,  atom_to_list(TableName) ++ ".dets").

create_db(TableName, GettextDir) ->
    create_db(TableName, GettextDir, db_filename(TableName, GettextDir)).

create_db(TableName, GettextDir, Fname) ->
    filelib:ensure_dir(Fname),
    init_db_table(TableName, GettextDir, Fname).

recreate_db(TableName, GettextDir) ->
    Fname = db_filename(TableName, GettextDir),
    dets:close(TableName),
    file:delete(Fname),
    create_db(TableName, GettextDir, Fname).

unload_custom_lang(TableName, GettextDir, Lang) ->
    Fname = filename:join([GettextDir, ?LANG_DIR, ?CUSTOM_DIR,
			   Lang, ?POFILE]),
    case filelib:is_file(Fname) of
	true ->
	    dets:match_delete(TableName, ?ENTRY(Lang,'_','_')),
            recreate_ets_table(TableName),
	    ok;
	false ->
	    {error, "no lang"}
    end.

reload_custom_lang(TableName, GettextDir, Lang) ->
    dets:match_delete(TableName, ?ENTRY(Lang,'_','_')),
    Dir = filename:join([GettextDir, ?LANG_DIR, ?CUSTOM_DIR, Lang]),
    Fname = filename:join([Dir, ?POFILE]),
    insert_po_file(TableName, Lang, Fname),
    recreate_ets_table(TableName),
    ok.

store_pofile(TableName, Lang, File, GettextDir, Cache) ->
    Dir = filename:join([GettextDir, ?LANG_DIR, ?CUSTOM_DIR, Lang]),
    Fname = filename:join([Dir, ?POFILE]),
    filelib:ensure_dir(Fname),
    case file:write_file(Fname, File) of
	ok ->
	    case lists:keymember(Lang, #cache.language, Cache) of
		true  -> delete_lc(TableName, Lang);
		false -> false
	    end,
	    insert_po_file(TableName, Lang, Fname),
	    {ok, [set_charset(TableName, #cache{language = Lang}) | Cache]};
	_ ->
	    {error, "failed to write PO file to disk"}
    end.

set_charset(TableName, C) ->
    case lookup(TableName, C#cache.language, ?GETTEXT_HEADER_INFO) of
	?GETTEXT_HEADER_INFO ->                   % nothing found...
	    C#cache{charset = ?DEFAULT_CHARSET};  % fallback
	Pfinfo ->
	    CharSet = get_charset(Pfinfo),
	    C#cache{charset = CharSet}
    end.


get_charset(Pfinfo) ->
    g_charset(string:tokens(Pfinfo,[$\n])).

g_charset(["Content-Type:" ++ Rest|_]) -> g_cset(Rest);
g_charset([_H|T])                      -> g_charset(T);
g_charset([])                          -> ?DEFAULT_CHARSET.

g_cset("charset=" ++ Charset) -> rm_trailing_stuff(Charset);
g_cset([_|T])                 -> g_cset(T);
g_cset([])                    -> ?DEFAULT_CHARSET.

rm_trailing_stuff(Charset) ->
    lists:reverse(eat_dust(lists:reverse(Charset))).

eat_dust([$\s|T]) -> eat_dust(T);
eat_dust([$\n|T]) -> eat_dust(T);
eat_dust([$\r|T]) -> eat_dust(T);
eat_dust([$\t|T]) -> eat_dust(T);
eat_dust(T)       -> T.


init_db_table(TableName, GettextDir, TableFile) ->
    case filelib:is_regular(TableFile) of
	false ->
	    create_and_populate(TableName, GettextDir, TableFile);
	true ->
	    %% If the dets file is broken, dets may not be able to repair it
	    %% itself (it may be only half-written). So check and recreate
	    %% if needed instead.
	    case open_dets_file(TableName, TableFile) of
		ok -> create_cache(TableName);
		_  -> create_and_populate(TableName, GettextDir, TableFile)
	    end
    end.

create_cache(TableName) ->
    F = fun(LC, Acc) ->
		case lookup(TableName, LC, ?GETTEXT_HEADER_INFO) of
		    ?GETTEXT_HEADER_INFO ->
			%% nothing found...
			?elog("Could not find header info for lang: ~s~n",[LC]),
			Acc;
		    Pfinfo ->
			CS = get_charset(Pfinfo),
			[#cache{language = LC, charset = CS}|Acc]
		end
	end,
    recreate_ets_table(TableName),
    lists:foldl(F, [], all_lcs_dets(TableName)).

create_and_populate(TableName, GettextDir, TableFile) ->
    ?elog("TableFile = ~p~n", [TableFile]),
    %% Need to create and populate the DB.
    {ok, _} = dets:open_file(TableName,
			     [{file, TableFile},
			      %% creating on disk, esp w auto_save,
			      %% takes "forever" on flash disk
			      {ram_file, true}]),
    L = populate_db(TableName, GettextDir),
    dets:close(TableName),    % flush to disk
    {ok, _} = dets:open_file(TableName, [{file, TableFile}]),
    recreate_ets_table(TableName),
    L.

recreate_ets_table(TableName) ->
    try ets:delete(get(ets_table))
    catch _:_ -> true
    after
        create_and_populate_ets_table(TableName)
    end.

%% To speed up the read access 10-100 times !!
create_and_populate_ets_table(TableName) ->
    try
        E = ets:new(?MODULE, [set, private]),
	put(ets_table, E),
        ets:from_dets(E, TableName),
        true
    catch
            _:_ -> false
    end.



open_dets_file(Tname, Fname) ->
    Opts = [{file, Fname}, {repair, false}],
    case dets:open_file(Tname, Opts) of
	{ok, _} ->
	    ok;
	_ ->
	    file:delete(Fname),
	    error
    end.

%%%
%%% Insert the given languages into the DB.
%%%
%%% NB: It is important to insert the 'predefined' language
%%%     definitions first since a custom language should be
%%%     able to 'shadow' the the same predefined language.
%%%
populate_db(TableName, GettextDir) ->
    L = insert_predefined(TableName, GettextDir, []),
    insert_custom(TableName, GettextDir, L).

insert_predefined(TableName, GettextDir, L) ->
    Dir = filename:join([GettextDir, ?LANG_DIR, ?DEFAULT_DIR]),
    insert_data(TableName, Dir, L).

insert_data(TableName, Dir, L) ->
    case file:list_dir(Dir) of
	{ok, Dirs} ->
	    %% TODO: this should accept only *.po-files, not just filter some
	    F = fun([$.|_], Acc)     -> Acc;  % ignore in a local inst. env.
		   ("CVS" ++ _, Acc) -> Acc;  % ignore in a local inst. env.
		   (LC, Acc)         ->
			Fname = filename:join([Dir, LC, ?POFILE]),
			insert_po_file(TableName, LC, Fname),
                        case lookup(TableName, LC, ?GETTEXT_HEADER_INFO) of
                            ?GETTEXT_HEADER_INFO ->
                                %% nothing found...
                                ?elog("Could not find header info for lang: ~s~n",[LC]),
                                [#cache{language = LC} | Acc];
                            Pfinfo ->
                                CS = get_charset(Pfinfo),
                                [#cache{language = LC, charset = CS}|Acc]
                        end
		end,
	    lists:foldl(F, L, Dirs);
	_ ->
	    L
    end.

insert_po_file(TableName, LC, Fname) ->
    case file:read_file_info(Fname) of
	{ok, _} ->
	    insert(TableName, LC, gettext:parse_po(Fname));
	_ ->
	    ?elog("gettext_server: Could not read ~s~n", [Fname]),
	    {error, "could not read PO file"}
    end.

insert_custom(TableName, GettextDir, L) ->
    Dir = filename:join([GettextDir, ?LANG_DIR, ?CUSTOM_DIR]),
    insert_data(TableName, Dir, L).

insert(TableName, LC, L) ->
    F = fun({Key, Val}) ->
		dets:insert(TableName, ?ENTRY(LC, Key, Val))
	end,
    lists:foreach(F, L).

lookup(TableName, Lang, Key) ->
	lookup(TableName, Lang, Lang, Key).

lookup(TableName, Lang, DefaultLang, Key) ->
    try ets:lookup(get(ets_table), ?KEY(Lang, Key)) of
	[] ->  case string:equal(Lang, DefaultLang) of
				true -> Key;
				false -> lookup(TableName, DefaultLang, Key)
			end;
	[?ENTRY(_,_,Str)|_] -> Str
    catch
        _:_ ->
	    case dets:lookup(TableName, ?KEY(Lang, Key)) of
		[]          -> Key;
		[?ENTRY(_,_,Str)|_] -> Str
	    end
    end.


delete_lc(TableName, LC) ->
    dets:match_delete(TableName, ?ENTRY(LC, '_', '_')).


all_lcs_dets(TableName) ->
    L = dets:match(TableName, ?ENTRY('$1', ?GETTEXT_HEADER_INFO, '_')),
    [hd(X) || X <- L].
