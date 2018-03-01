defmodule Chat do
  use Application
  def start(_type, _args) do
    ChatSupervisor.start_link()
    dispatch = :cowboy_router.compile([
      {:_, [{"/ws", ChatWebsocketHandler, []}]}
    ])

    :cowboy.start_clear(:ws_listener, [port: 8080], %{:env => %{:dispatch => dispatch}})
  end

  def stop(_state) do
    :ok
  end
end

defmodule ChatWebsocketHandler do
  def init(req, _state) do
    {:cowboy_websocket, req, _newState = %{}, %{:idle_timeout => 60000 * 20}}
  end

  def websocket_init(state) do
    {:ok, state}
  end

  def websocket_handle({:text, data}, state) do
    term = Eljiffy.decode_maps(data)
    command = term["command"]
    state = case command do
      "new-room" ->
      	{:ok, pid} = ChatSupervisor.newRoom(term["room"])
        Map.put(state, :room, %{name: term["room"], pid: pid})
      "join" ->
	{:ok, _name, pid} = ChatSupervisor.joinRoom(term["room"], self(), term["name"])
        Map.put(state, :room, %{name: term["room"], pid: pid})
      "msg" ->
        ChatRoom.bcast(state.room.pid, term["msg"], term["name"])
    end
    {:ok, state}
  end

  def websocket_info({:msg, msg}, state) do
    data = Eljiffy.encode(msg)
    {:reply, {:text, data}, state}
  end
end

defmodule ChatRoom do
  use GenServer
  def start_link(roomId) do
    GenServer.start_link(__MODULE__, [roomId], [])
  end

  def init([roomId]) do
    {:ok, %{:clients => %{}, :roomId => roomId}}
  end

  def handle_cast({:bcast, msg, from}, state) do
    case state.clients[from] do
      nil ->
        :ok
      _pid ->
        for client <- Map.keys(state.clients), do: send(client, %{from: from, message: msg})
    end
    {:noreply, state}
  end

  def handle_call({:add_client, clientPid, name}, _from, state) do
    case state.clients[clientPid] do
      nil ->
        {:reply, {:ok, name}, %{state | :clients => Map.put(state.clients, clientPid, name)}}
      _ ->
        {:reply, {:error, :name_taken}, state}
    end
  end

  def child_spec([roomId]) do
    %{
      id: roomId,
      restart: :permanent,
      shutdown: 5000,
      start: {__MODULE__, :start_link, [roomId]},
      type: :worker
    }
  end

  def add_client(chatRoom, pid, name) do
    GenServer.call(chatRoom, {:add_client, pid, name})
  end

  def bcast(chatRoom, from, msg) do
    GenServer.cast(chatRoom, {:bcast, msg, from})
    :ok
  end
end

###################################################################################
####################################SUPERVISORS####################################
###################################################################################

defmodule ChatSupervisor do
  use Supervisor
  def start_link() do
    Supervisor.start_link(__MODULE__, [], [name: __MODULE__])
  end

  def init([]) do
    children = [
      #{ChatRoomSupervisor, [1]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def joinRoom(roomId, clientPid, clientName) do
    case for {id, pid, _type, _modules} <- Supervisor.which_children(__MODULE__), id == roomId, do: pid do
      [supPid] ->
        ChatRoomSupervisor.joinRoom(supPid, roomId, clientPid, clientName)
      _ ->
        {:error, :bad_room_id}
    end
  end

  def newRoom(roomId) do
    case for {id, _child, _type, _modules} <- Supervisor.which_children(__MODULE__), id == roomId, do: id do
      [] ->
        {:ok, supPid} = Supervisor.start_child(__MODULE__, ChatRoomSupervisor.child_spec([roomId]))
	[pid] = for {id, pid, _, _} <- Supervisor.which_children(supPid), id == roomId, do: pid
	
        {:ok, pid}
      _ ->
        {:error, :room_exists}
    end
  end
end

defmodule ChatRoomSupervisor do
  use Supervisor
  def start_link([roomId]) do
    Supervisor.start_link(__MODULE__, [roomId], [])
  end

  def init([roomId]) do
    children = [
      {ChatRoom, [roomId]}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  def joinRoom(pid, roomId, clientPid, clientName) do
    case for {id, pid, _, _} <- Supervisor.which_children(pid), id == roomId, do: pid do
      [] ->
        {:error, :bad_room_id}
      [roomPid] ->
        {:ok, ^clientName} = ChatRoom.add_client(roomPid, clientPid, clientName)
	{:ok, clientName, roomPid}
    end
  end

  def getRoomPid(pid) do
    [roomPid] = for {roomPid, _, _, modules} <- Supervisor.which_children(pid), modules == [ChatRoom], do: roomPid
    roomPid
  end

  def child_spec([roomId]) do
    %{
      id: roomId,
      restart: :permanent,
      shutdown: 5000,
      start: {__MODULE__, :start_link, [[roomId]]},
      type: :supervisor
    }
  end
end
