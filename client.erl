-module(client).

-behaviour(gen_server).

%% API
-export([start_link/2, get_jid/0,
	 register_listener/1, unregister_listener/1,
	 send/1, send_recv/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include_lib("exmpp.hrl").
-include_lib("exmpp_client.hrl").

-record(state, {session, jid, listeners = [], waiters = [], lastid = 0}).
-record(reply_waiter, {from_id, caller, call_time}).
-define(SERVER, ?MODULE).

-define(SEND_RECV_TIMEOUT, 60).

%%====================================================================
%% API
%%====================================================================
start_link(JID, Password) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [JID, Password], []).

get_jid() ->
    case gen_server:call(?SERVER, get_jid) of
	#jid{} = JID ->
	    exmpp_jid:jid_to_list(JID);
	JID ->
	    JID
    end.

register_listener(Module) ->
    gen_server:call(?SERVER, {register_listener, Module}).

unregister_listener(Module) ->
    gen_server:call(?SERVER, {unregister_listener, Module}).

send(#xmlelement{} = Stanza) ->
    send(exmpp_xml:xmlelement_to_xmlel(Stanza));
send(Stanza) ->
    gen_server:call(?SERVER, {send, Stanza}).

send_recv(#xmlelement{} = Stanza) ->
    send_recv(exmpp_xml:xmlelement_to_xmlel(Stanza));
send_recv(Stanza) ->
    gen_server:call(?SERVER, {send_and_wait, Stanza}, ?SEND_RECV_TIMEOUT * 1000).

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([JID, Password]) ->
    Session = exmpp_session:start(),
    JID1 = exmpp_jid:list_to_jid(JID),
    exmpp_session:auth_basic_digest(Session, JID1, Password),
    %% What's with SRV records?
    _StreamId = exmpp_session:connect_TCP(Session, JID1#jid.domain, 5222),
    exmpp_session:login(Session),
    exmpp_session:send_packet(Session,
			      exmpp_presence:set_status(
                                exmpp_presence:available(), "Just booted")),


    {ok, #state{session = Session, jid = JID}}.

handle_call(get_jid, _From,
	    #state{jid = JID} = State) ->
    {reply, JID, State};

handle_call({register_listener, Module}, _From,
	    #state{listeners = Listeners} = State) ->
    {reply, ok, State#state{listeners = [Module | Listeners]}};

handle_call({unregister_listener, Module}, _From,
	    #state{listeners = Listeners} = State) ->
    {reply, ok, State#state{listeners = Listeners -- [Module]}};

handle_call({send, Stanza}, _From,
	    #state{session = Session} = State) ->
    error_logger:info_msg("Sending ~s~n", [exmpp_xml:node_to_list(Stanza, [], [])]),
    R = exmpp_session:send_packet(Session, Stanza),
    {reply, R, State};

handle_call({send_and_wait, Stanza}, Caller,
	    #state{session = Session,
		   waiters = Waiters,
		   lastid = LastId} = State) ->
    To = exmpp_xml:get_attribute(Stanza, to, undefined),
    Id = LastId + random:uniform(100),
    IdS = lists:flatten(io_lib:format("~B", [Id])),
    Stanza2 = exmpp_xml:set_attribute(Stanza, id, IdS),
    error_logger:info_msg("Sending and waiting ~s~n", [exmpp_xml:node_to_list(Stanza2, [], [])]),
    exmpp_session:send_packet(Session, Stanza2),
    Waiter = #reply_waiter{from_id = {To, IdS},
			   caller = Caller,
			   call_time = current_time()},
    {noreply, State#state{waiters = [Waiter | expire_reply_waiters(Waiters)],
			  lastid = Id},
     ?SEND_RECV_TIMEOUT * 1000}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(#received_packet{raw_packet = Pkt},
	    #state{waiters = Waiters} = State) ->
    error_logger:info_msg("Received ~p~n", [Pkt]),
    From = exmpp_xml:get_attribute(Pkt, from, undefined),
    Id = exmpp_xml:get_attribute(Pkt, id, undefined),
    case lists:keysearch({From, Id}, #reply_waiter.from_id, Waiters) of
	{value, #reply_waiter{caller = Caller} = W} ->
	    NewWaiters = lists:delete(W, Waiters),
	    gen_server:reply(Caller, Pkt),
	    {noreply, State#state{waiters = NewWaiters}};
	false ->
	    spawn(fun() -> notify_listeners(Pkt, State#state.listeners) end),
	    {noreply, State}
    end;

handle_info(timeout, #state{waiters = Waiters} = State) ->
    {noreply, State#state{waiters = expire_reply_waiters(Waiters)}};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

%% Calls all Listeners:handle_packet(Pkt, Session) 
notify_listeners(Pkt, Listeners) ->
    lists:foldl(
      fun(Listener, ignored) ->
	      case (catch Listener:handle_packet(Pkt)) of
		  {'EXIT', Reason} ->
		      error_logger:error_msg("Error calling ~s for packet ~p:~n~p~n",
					     [Listener, Pkt, Reason]),
		      ignored;
		  ignored ->
		      ignored;
		  Result ->
		      Result
	      end;
	 (_Listener, Result) ->
	      Result
      end, ignored, Listeners).

expire_reply_waiters(Waiters) ->
    TimeMin = current_time() - ?SEND_RECV_TIMEOUT,
    [Waiter
     || #reply_waiter{call_time = Time} = Waiter <- Waiters,
	Time > TimeMin].

current_time() ->
    {M, S, _} = now(),
    M * 1000000 + S.