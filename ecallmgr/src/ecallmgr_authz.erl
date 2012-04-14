%%%-------------------------------------------------------------------
%%% @author James Aimonetti <james@2600hz.org>
%%% @copyright (C) 2011, VoIP, INC
%%% @doc
%%% Make a request for authorization, and answer queries about the CallID
%%% @end
%%% Created :  7 Jul 2011 by James Aimonetti <james@2600hz.org>
%%%-------------------------------------------------------------------
-module(ecallmgr_authz).

-export([authorize/3, is_authorized/1, default/0, authz_win/1]).

-export([init_authorize/4, enable_authz/0, disable_authz/0]).

-include("ecallmgr.hrl").

-define(AUTHZ_LOOP_TIMEOUT, 5000).

%% If authz_default is set to allow, the call is authorized
%% otherwise, the call is not authorized
-spec default/0 :: () -> {boolean(), []}.
default() ->
    case ecallmgr_util:get_setting(<<"authz_default">>, <<"deny">>) of
        {ok, <<"allow">>} -> {true, []};
        _ -> {false, []}
    end.

enable_authz() ->
    ecallmgr_config:set(<<"authz_enabled">>, true).

disable_authz() ->
    ecallmgr_config:set(<<"authz_enabled">>, false).

-spec authorize/3 :: (ne_binary(), ne_binary(), proplist()) -> {'ok', pid()}.
authorize(FSID, CallID, FSData) ->
    proc_lib:start_link(?MODULE, init_authorize, [self(), FSID, CallID, FSData]).

-spec is_authorized/1 :: (pid() | 'undefined') -> {boolean(), wh_json:json_object()}.
is_authorized(Pid) when is_pid(Pid) ->
    Ref = make_ref(),
    Pid ! {is_authorized, self(), Ref},
    receive
        {is_authorized, Ref, IsAuth, CCV} -> {IsAuth, CCV}
    after
        1000 -> default()
    end;
is_authorized(undefined) -> {false, []}.

-spec authz_win/1 :: (pid() | 'undefined') -> 'ok'.
authz_win(undefined) -> 'ok';
authz_win(Pid) when is_pid(Pid) ->
    Ref = make_ref(),
    Pid ! {authz_win, self(), Ref},
    receive
        {authz_win_sent, Ref} -> ok
    after 1000 ->
            lager:debug("Timed out sending authz_win, odd")
    end.


-spec init_authorize/4 :: (pid(), ne_binary(), ne_binary(), proplist()) -> no_return().
init_authorize(Parent, FSID, CallID, FSData) ->
    proc_lib:init_ack(Parent, {ok, self()}),
    put(callid, CallID),
    lager:debug("authorize started"),
    ReqResp = wh_amqp_worker:call(?ECALLMGR_AMQP_POOL
                                  ,request(FSID, CallID, FSData)
                                  ,fun wapi_authz:publish_req/1
                                  ,fun wapi_authz:is_authorized/1),
    case ReqResp of 
        {error, _R} -> 
            lager:debug("authz request lookup failed: ~p", [_R]),
            default();
        {ok, RespJObj} ->
            authorize_loop(RespJObj)
    end.

-spec authorize_loop/1 :: (wh_json:json_object()) -> no_return().
authorize_loop(JObj) ->
    receive
        {is_authorized, From, Ref} ->
            IsAuthz = wh_util:is_true(wh_json:get_value(<<"Is-Authorized">>, JObj)),
            CCV = wh_json:get_value(<<"Custom-Channel-Vars">>, JObj, []),
            lager:debug("Is authz: ~s", [IsAuthz]),
            From ! {is_authorized, Ref, IsAuthz, CCV},
            authorize_loop(JObj);

        {authz_win, From, Ref} ->
            wapi_authz:publish_win(wh_json:get_value(<<"Server-ID">>, JObj), wh_json:delete_key(<<"Event-Name">>, JObj)),
            lager:debug("sent authz_win, nice"),

            From ! {authz_win_sent, Ref},

            authorize_loop(JObj);

        _ -> authorize_loop(JObj)
    after ?AUTHZ_LOOP_TIMEOUT ->
            lager:debug("going down from timeout")
    end.

-spec request/3 :: (ne_binary(), ne_binary(), proplist()) -> proplist().
request(FSID, CallID, FSData) ->
    [{<<"Msg-ID">>, FSID}
     ,{<<"Caller-ID-Name">>, props:get_value(<<"Caller-Caller-ID-Name">>, FSData, <<"noname">>)}
     ,{<<"Caller-ID-Number">>, props:get_value(<<"Caller-Caller-ID-Number">>, FSData, <<"0000000000">>)}
     ,{<<"To">>, ecallmgr_util:get_sip_to(FSData)}
     ,{<<"From">>, ecallmgr_util:get_sip_from(FSData)}
     ,{<<"Request">>, ecallmgr_util:get_sip_request(FSData)}
     ,{<<"Call-ID">>, CallID}
     ,{<<"Custom-Channel-Vars">>, wh_json:from_list(ecallmgr_util:custom_channel_vars(FSData))}
     | wh_api:default_headers(<<>>, <<"dialplan">>, <<"authz_req">>, ?APP_NAME, ?APP_VERSION)].
