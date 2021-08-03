-module(dds_publisher).

-behaviour(gen_server).

-export([start_link/0, create_datawriter/2,lookup_datawriter/2,on_data_available/2,dispose_data_writers/1,wait_for_acknoledgements/1]).%set_publication_subscriber/2,suspend_publications/1,resume_pubblications/1]).
-export([init/1, handle_call/3, handle_cast/2,handle_info/2]).


-include_lib("dds/include/dds_types.hrl").
-include_lib("dds/include/rtps_structure.hrl").
-include_lib("dds/include/rtps_constants.hrl").

-record(state,{
        rtps_participant_info=#participant{},
        builtin_pub_announcer,
        builtin_sub_announcer,
        data_writers = [],
        incremental_key=1}).

start_link() -> gen_server:start_link( ?MODULE, [],[]).
on_data_available(Name,{R,ChangeKey}) -> 
        [Pid|_] = pg:get_members(Name),
        gen_server:cast(Pid, {on_data_available, {R,ChangeKey}}).
create_datawriter(Name,Topic) -> 
        [Pid|_] = pg:get_members(Name),
        gen_server:call(Pid,{create_datawriter,Topic}).
lookup_datawriter(Name,Topic) -> 
        [Pid|_] = pg:get_members(Name),
        gen_server:call(Pid,{lookup_datawriter,Topic}).
dispose_data_writers(Name) -> 
        [Pid|_] = pg:get_members(Name),
        gen_server:call(Pid,dispose_data_writers).
wait_for_acknoledgements(Name) -> 
        [Pid|_] = pg:get_members(Name),
        gen_server:call(Pid,wait_for_acknoledgements).
%callbacks 
init([]) ->  
        process_flag(trap_exit, true),
        pg:join(dds_default_publisher, self()),
        
        P_info = rtps_participant:get_info(participant),
        SPDP_W_cfg = rtps_participant:get_spdp_writer_config(participant),
        {ok, _ } = supervisor:start_child(dds_datawriters_pool_sup, [{discovery_writer,P_info,SPDP_W_cfg}]),
        
        % the Subscription-writer(aka announcer) will forward my willing to listen to defined topics
        GUID_s = #guId{ prefix = P_info#participant.guid#guId.prefix, 
                        entityId = ?ENTITYID_SEDP_BUILTIN_SUBSCRIPTIONS_ANNOUNCER},        
        SEDP_Sub_Config = #endPoint{guid = GUID_s},
        {ok, _ } = supervisor:start_child(dds_datawriters_pool_sup, 
                        [{data_writer, builtin_sub_announcer, P_info, SEDP_Sub_Config}]),

        %the publication-writer(aka announcer) will forward my willing to talk to defined topics
        GUID_p = #guId{ prefix =  P_info#participant.guid#guId.prefix, 
                        entityId = ?ENTITYID_SEDP_BUILTIN_PUBLICATIONS_ANNOUNCER},        
        SEDP_Pub_Config = #endPoint{guid = GUID_p},
        {ok, _ } = supervisor:start_child(dds_datawriters_pool_sup, 
                        [{data_writer, builtin_pub_announcer, P_info, SEDP_Pub_Config}]),

        % the publisher listens to the sub_detector to add remote readers to its writers
        SubDetector = dds_subscriber:lookup_datareader(dds_default_subscriber, builtin_sub_detector),
        dds_data_r:set_listener(SubDetector, {dds_default_publisher, ?MODULE}),
        
        {ok,#state{ rtps_participant_info=P_info, 
                builtin_pub_announcer= {data_w_of, GUID_p}, 
                builtin_sub_announcer = {data_w_of, GUID_s}}}.

handle_call({create_datawriter,Topic}, _, 
                #state{rtps_participant_info=P_info,data_writers=Writers, 
                builtin_pub_announcer=PubAnnouncer, incremental_key = K}=S) -> 
        % Endpoint creation        
        EntityID = #entityId{kind=?EKIND_USER_Writer_NO_Key,key = <<K:24>>},
        GUID = #guId{ prefix =  P_info#participant.guid#guId.prefix, entityId = EntityID},      
        Config = #endPoint{guid = GUID}, 
        {ok, _} = supervisor:start_child(dds_datawriters_pool_sup,
                [{data_writer, Topic, P_info, Config}]),
        % Endpoint announcement
        dds_data_w:write(PubAnnouncer, produce_sedp_disc_enpoint_data(P_info, Topic, EntityID)),
        {reply, {data_w_of,GUID}, 
                S#state{data_writers = Writers ++ [{EntityID,Topic,{data_w_of,GUID}}], incremental_key = K+1 }};

handle_call({lookup_datawriter,builtin_sub_announcer}, _, State) -> {reply,State#state.builtin_sub_announcer,State};
handle_call({lookup_datawriter,builtin_pub_announcer}, _, State) -> {reply,State#state.builtin_pub_announcer,State};
handle_call({lookup_datawriter,Topic}, _, #state{data_writers=DW} = S) -> 
        [W|_] = [ Name || {_,T,Name} <- DW, T==Topic ],
        {reply, W, S};
handle_call(dispose_data_writers, _, #state{rtps_participant_info= P_info, builtin_pub_announcer = Pub_announcer, data_writers=DW} = S) -> 
        [ dds_data_w:write(Pub_announcer, produce_sedp_endpoint_leaving(P_info,ID)) || {ID,_,_} <- DW],
        dds_data_w:flush_all_changes(Pub_announcer),
        {reply, ok, S};
handle_call(wait_for_acknoledgements, _, #state{rtps_participant_info= P_info, builtin_pub_announcer = Pub_announcer, data_writers=DW} = S) -> 
        [ dds_data_w:wait_for_acknoledgements(Pub_announcer) || {ID,_,_} <- DW],
        {reply, ok, S};
handle_call(_, _, State) -> {reply,ok,State}.
handle_cast({on_data_available,{R,ChangeKey}}, #state{data_writers=DW}=S) -> 
        Change = dds_data_r:read(R,ChangeKey),  %io:format("DDS: change: ~p, with key: ~p\n", [Change,ChangeKey]),
        Data = Change#cacheChange.data,
        case ?ENDPOINT_LEAVING(Data#sedp_disc_endpoint_data.status_qos) of 
                true -> %io:format("I should remove some ReaderProxy\n"),
                        [ dds_data_w:remote_reader_remove(Name,Data#sedp_disc_endpoint_data.endpointGuid) || 
                                                                                                {_,T,Name} <- DW ];
                _ ->  
                        ToBeMatched = [ Pid || {_,T,Pid} <- DW, T#user_topic.name == Data#sedp_disc_endpoint_data.topic_name],
                        io:format("DDS: node willing to subscribe to topic : ~p\n", [Data#sedp_disc_endpoint_data.topic_name]),
                        %io:format("DDS: i have theese topics: ~p\n", [[ T || {_,T,Pid} <- DW]]),
                        %io:format("DDS: interested writers are: ~p\n", [ToBeMatched]),
                        [P|_] = [P || #spdp_disc_part_data{guidPrefix = Pref}=P <- dds_domain_participant:get_discovered_participants(dds), 
                                                         Pref == Data#sedp_disc_endpoint_data.endpointGuid#guId.prefix],
                        Proxy = #reader_proxy{guid = Data#sedp_disc_endpoint_data.endpointGuid,        
                                unicastLocatorList = P#spdp_disc_part_data.default_uni_locator_l,
                                multicastLocatorList = P#spdp_disc_part_data.default_multi_locato_l},
                        [ dds_data_w:remote_reader_add(Pid,Proxy) || Pid <- ToBeMatched ]
        end,
        {noreply,S};
handle_cast(_, State) -> {noreply,State}.

handle_info(_,State) -> {noreply,State}.


% HELPERS
produce_sedp_disc_enpoint_data(#participant{guid=#guId{prefix=P},vendorId=VID,protocolVersion=PVER},
                #user_topic{ type_name=TN, name=N, 
                                qos_profile=#qos_profile{reliability=R,durability=D,history=H}},
                EntityID) -> 
        #sedp_disc_endpoint_data{
                dst_reader_id = ?ENTITYID_SEDP_BUILTIN_PUBLICATIONS_DETECTOR,
                endpointGuid= #guId{prefix = P, entityId = EntityID},
                topic_type=TN,
                topic_name=N,
                protocolVersion=PVER,
                vendorId=VID,
                history_qos = H,
                durability_qos = D,
                reliability_qos = R
        }.

produce_sedp_endpoint_leaving(#participant{guid=#guId{prefix=P}},EntityID) -> 
        #sedp_endpoint_state{
                guid = #guId{prefix=P, entityId = EntityID},
                status_flags = ?STATUS_INFO_UNREGISTERED + ?STATUS_INFO_DISPOSED
        }.