%%--------------------------------------------------------------------
%% Copyright (c) 2012-2016 Feng Lee <feng@emqtt.io>.
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
%%--------------------------------------------------------------------

-module(emqttd).

-author("Feng Lee <feng@emqtt.io>").

-include("emqttd.hrl").

-include("emqttd_protocol.hrl").

-export([start/0, conf/1, conf/2, env/1, env/2, is_running/1]).

%% PubSub API
-export([subscribe/1, subscribe/2, subscribe/3, publish/1,
         unsubscribe/1, unsubscribe/2]).

%% PubSub Management API
-export([topics/0, subscribers/1, subscriptions/1]).

%% Hooks API
-export([hook/4, hook/3, unhook/2, run_hooks/3]).

%% Debug API
-export([dump/0]).

-type(subscriber() :: pid() | binary() | function()).

-type(suboption() :: local | {qos, non_neg_integer()} | {share, {'$queue' | binary()}}).

-type(pubsub_error() :: {error, {already_subscribed, binary()}
                              | {subscription_not_found, binary()}}).

-export_type([subscriber/0, suboption/0, pubsub_error/0]).

-define(APP, ?MODULE).

%%--------------------------------------------------------------------
%% Bootstrap, environment, configuration, is_running...
%%--------------------------------------------------------------------

%% @doc Start emqttd application.
-spec(start() -> ok | {error, any()}).
start() -> application:start(?APP).

%% @doc Get Config
-spec(conf(Key :: atom()) -> any()).
conf(Key) -> gen_conf:value(?APP, Key).

-spec(conf(Key :: atom(), Default :: any()) -> any()).
conf(Key, Default) -> gen_conf:value(?APP, Key, Default).

%% @doc Environment
-spec(env(Key:: atom()) -> any()).
env(Key) -> application:get_env(?APP, Key).

%% @doc Get environment
-spec(env(Key:: atom(), Default:: any()) -> undefined | any()).
env(Key, Default) -> application:get_env(?APP, Key, Default).

%% @doc Is running?
-spec(is_running(node()) -> boolean()).
is_running(Node) ->
    case rpc:call(Node, erlang, whereis, [?APP]) of
        {badrpc, _}          -> false;
        undefined            -> false;
        Pid when is_pid(Pid) -> true
    end.

%%--------------------------------------------------------------------
%% PubSub APIs that wrap emqttd_pubsub
%%--------------------------------------------------------------------

%% @doc Subscribe
-spec(subscribe(iodata()) -> ok | {error, any()}).
subscribe(Topic) ->
    subscribe(Topic, self()).

-spec(subscribe(iodata(), subscriber()) -> ok | {error, any()}).
subscribe(Topic, Subscriber) ->
    subscribe(Topic, Subscriber, []).

-spec(subscribe(iodata(), subscriber(), [suboption()]) -> ok | pubsub_error()).
subscribe(Topic, Subscriber, Options) ->
    with_pubsub(fun(PubSub) -> PubSub:subscribe(iolist_to_binary(Topic), Subscriber, Options) end).

%% @doc Publish MQTT Message
-spec(publish(mqtt_message()) -> {ok, mqtt_delivery()} | ignore).
publish(Msg = #mqtt_message{from = From}) ->
    trace(publish, From, Msg),
    case run_hooks('message.publish', [], Msg) of
        {ok, Msg1 = #mqtt_message{topic = Topic}} ->
            %% Retain message first. Don't create retained topic.
            Msg2 = case emqttd_retainer:retain(Msg1) of
                       ok     -> emqttd_message:unset_flag(Msg1);
                       ignore -> Msg1
                   end,
            with_pubsub(fun(PubSub) -> PubSub:publish(Topic, Msg2) end);
        {stop, Msg1} ->
            lager:warning("Stop publishing: ~s", [emqttd_message:format(Msg1)]),
            ignore
    end.

%% @doc Unsubscribe
-spec(unsubscribe(iodata()) -> ok | pubsub_error()).
unsubscribe(Topic) ->
    unsubscribe(Topic, self()).

-spec(unsubscribe(iodata(), subscriber()) -> ok | pubsub_error()).
unsubscribe(Topic, Subscriber) ->
    with_pubsub(fun(PubSub) -> PubSub:unsubscribe(iolist_to_binary(Topic), Subscriber) end).

-spec(topics() -> [binary()]).
topics() -> with_pubsub(fun(PubSub) -> PubSub:topics() end).

-spec(subscribers(iodata()) -> list(subscriber())).
subscribers(Topic) ->
    with_pubsub(fun(PubSub) -> PubSub:subscribers(iolist_to_binary(Topic)) end).

-spec(subscriptions(subscriber()) -> [{binary(), suboption()}]).
subscriptions(Subscriber) ->
    with_pubsub(fun(PubSub) -> PubSub:subscriptions(Subscriber) end).

with_pubsub(Fun) -> {ok, PubSub} = conf(pubsub_adapter), Fun(PubSub).

dump() -> with_pubsub(fun(PubSub) -> lists:append(PubSub:dump(), zenmq_router:dump()) end).

%%--------------------------------------------------------------------
%% Hooks API
%%--------------------------------------------------------------------

-spec(hook(atom(), function(), list(any())) -> ok | {error, any()}).
hook(Hook, Function, InitArgs) ->
    emqttd_hook:add(Hook, Function, InitArgs).

-spec(hook(atom(), function(), list(any()), integer()) -> ok | {error, any()}).
hook(Hook, Function, InitArgs, Priority) ->
    emqttd_hook:add(Hook, Function, InitArgs, Priority).

-spec(unhook(atom(), function()) -> ok | {error, any()}).
unhook(Hook, Function) ->
    emqttd_hook:delete(Hook, Function).

-spec(run_hooks(atom(), list(any()), any()) -> {ok | stop, any()}).
run_hooks(Hook, Args, Acc) ->
    emqttd_hook:run(Hook, Args, Acc).

%%--------------------------------------------------------------------
%% Trace Functions
%%--------------------------------------------------------------------

trace(publish, From, _Msg) when is_atom(From) ->
    %% Dont' trace '$SYS' publish
    ignore;

trace(publish, From, #mqtt_message{topic = Topic, payload = Payload}) ->
    lager:info([{client, From}, {topic, Topic}],
               "~s PUBLISH to ~s: ~p", [From, Topic, Payload]).

