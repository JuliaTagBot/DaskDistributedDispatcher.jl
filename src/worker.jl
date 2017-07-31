const no_value = "--no-value-sentinel--"


"""
    Worker

A `Worker` represents a worker endpoint in the distributed cluster. It accepts instructions
from the scheduler, fetches dependencies, executes compuations, stores data, and
communicates state to the scheduler.

# Fields
- `status::String`: status of this worker

- `address::Address`:: ip address and port that this worker is listening on
- `listener::Base.TCPServer`: tcp server that listens for incoming connections

- `scheduler_address::Address`: the dask-distributed scheduler ip address and port information
- `batched_stream::Nullable{BatchedSend}`: batched stream for communication with scheduler
- `scheduler::Rpc`: manager for discrete send/receive open connections to the scheduler
- `connection_pool::ConnectionPool`: manages connections to peers
- `total_connections::Integer`: maximum number of concurrent connections allowed

- `handlers::Dict{String, Function}`: handlers for operations requested by open connections
- `compute_stream_handlers::Dict{String, Function}`: handlers for compute stream operations

- `data::Dict{String, Any}`: maps keys to the results of function calls (actual values)
- `tasks::Dict{String, Tuple}`: maps keys to the function, args, and kwargs of a task
- `task_state::Dict{String, String}`: maps keys tot heir state: (waiting, executing, memory)
- `priorities::Dict{String, Tuple}`: run time order priority of a key given by the scheduler
- `priority_counter::Integer`: used to prioritize tasks by their order of arrival

- `transitions::Dict{Tuple, Function}`: valid transitions that a task can make
- `data_needed::Deque{String}`: keys whose data we still lack
- `ready::PriorityQueue{String, Tuple, Base.Order.ForwardOrdering}`: keys ready to run
- `executing::Set{String}`: keys that are currently executing

- `dep_transitions::Dict{Tuple, Function}`: valid transitions that a dependency can make
- `dep_state::Dict{String, String}`: maps dependencies with their state
    (waiting, flight, memory)
- `dependencies::Dict{String, Set}`: maps a key to the data it needs to run
- `dependents::Dict{String, Set}`: maps a dependency to the keys that use it
- `waiting_for_data::Dict{String, Set}`: maps a key to the data it needs that we don't have
- `pending_data_per_worker::DefaultDict{String, Deque}`: data per worker that we want
- `who_has::Dict{String, Set}`: maps keys to the workers believed to have their data
- `has_what::DefaultDict{String, Set{String}}`: maps workers to the data they have

- `in_flight_tasks::Dict{String, String}`: maps a dependency and the peer connection for it
- `in_flight_workers::Dict{String, Set}`: workers from which we are getting data from
- `suspicious_deps::DefaultDict{String, Integer}`: number of times a dependency has not been
    where it is expected
- `missing_dep_flight::Set{String}`: missing dependencies
"""
type Worker <: Server
    status::String

    # Server
    address::Address
    listener::Base.TCPServer

    # Communication management
    scheduler_address::Address
    batched_stream::Nullable{BatchedSend}
    scheduler::Rpc
    connection_pool::ConnectionPool
    total_connections::Integer

    # Handlers
    handlers::Dict{String, Function}
    compute_stream_handlers::Dict{String, Function}

    # Data and task management
    data::Dict{String, Any}
    tasks::Dict{String, Tuple}
    task_state::Dict{String, String}
    priorities::Dict{String, Tuple}
    priority_counter::Integer

    # Task state management
    transitions::Dict{Tuple{String, String}, Function}
    data_needed::Deque{String}
    ready::PriorityQueue{String, Tuple, Base.Order.ForwardOrdering}
    executing::Set{String}

    # Dependency management
    dep_transitions::Dict{Tuple{String, String}, Function}
    dep_state::Dict{String, String}
    dependencies::Dict{String, Set}
    dependents::Dict{String, Set}
    waiting_for_data::Dict{String, Set}
    pending_data_per_worker::DefaultDict{String, Deque{String}}
    who_has::Dict{String, Set{String}}
    has_what::DefaultDict{String, Set{String}}

    # Peer communication
    in_flight_tasks::Dict{String, String}
    in_flight_workers::Dict{String, Set{String}}
    suspicious_deps::DefaultDict{String, Integer}
    missing_dep_flight::Set{String}
end

"""
    Worker(scheduler_address::String="\$(getipaddr()):8786")

Create a `Worker` that listens on a random port between 1024 and 9000 for incoming
messages. By default if the scheduler's address is not provided it assumes that the
dask-scheduler is being run on the same machine and on the default port 8786.

**NOTE**: Worker's must be started in the same julia cluster as the `DaskExecutor` (and it's
`Client`).

## Usage

```julia
Worker()  # The dask-scheduler is being run on the same machine on its default port 8786.
```

or also

```julia
Worker("\$(getipaddr()):8786") # Scheduler is running on the same machine
```

If running the dask-scheduler on a different machine or port:

* First start the `dask-scheduler` and inspect its startup logs:

```
\$ dask-scheduler
distributed.scheduler - INFO - -----------------------------------------------
distributed.scheduler - INFO -   Scheduler at:   tcp://127.0.0.1:8786
distributed.scheduler - INFO - etc.
distributed.scheduler - INFO - -----------------------------------------------
```

* Then start workers with it's printed address:

```julia
Worker("tcp://127.0.0.1:8786")
```

No further actions are needed directly on the Worker's themselves as they will communicate
with the `dask-scheduler` independently. New `Worker`s can be added/removed at any time during
execution. There usually should be at least one `Worker` to run computations.

## Cleanup

To explicitly shutdown a worker and delete it's information use:

```julia
worker = Worker()
shutdown([worker.address])
```

It is more effective to explicitly reset the [`DaskExecutor`](@ref) or shutdown a
[`Client`](@ref) rather than a `Worker` because the dask-scheduler will automatically
re-schedule the lost computations on other `Workers` if it thinks that a [`Client`](@ref)
still needs the lost data.

`Worker`'s are lost if they were spawned on a julia process that exits or is removed
via `rmprocs` from the julia cluster. It is cleaner but not necessary to explicity call
`shutdown` if planning to remove a `Worker`.
"""
function Worker(scheduler_address::String="$(getipaddr()):8786")
    scheduler_address = Address(scheduler_address)
    port, listener = listenany(rand(1024:9000))
    worker_address = Address(getipaddr(), port)

    # This is the minimal set of handlers needed
    # https://github.com/JuliaParallel/Dagger.jl/issues/53
    handlers = Dict{String, Function}(
        "get_data" => get_data,
        "gather" => gather,
        "update_data" => update_data,
        "delete_data" => delete_data,
        "terminate" => terminate,
        "keys" => get_keys,
    )
    compute_stream_handlers = Dict{String, Function}(
        "compute-task" => add_task,
        "release-task" => release_key,
        "delete-data" => delete_data,
    )
    transitions = Dict{Tuple{String, String}, Function}(
        ("waiting", "ready") => transition_waiting_ready,
        ("waiting", "memory") => transition_waiting_done,
        ("ready", "executing") => transition_ready_executing,
        ("ready", "memory") => transition_ready_memory,
        ("executing", "memory") => transition_executing_done,
    )
    dep_transitions = Dict{Tuple{String, String}, Function}(
        ("waiting", "flight") => transition_dep_waiting_flight,
        ("waiting", "memory") => transition_dep_waiting_memory,
        ("flight", "waiting") => transition_dep_flight_waiting,
        ("flight", "memory") => transition_dep_flight_memory,
    )
    worker = Worker(
        "starting",  # status

        worker_address,
        listener,

        scheduler_address,
        nothing, #  batched_stream
        Rpc(scheduler_address),  # scheduler
        ConnectionPool(),  # connection_pool
        50,  # total_connections

        handlers,
        compute_stream_handlers,

        Dict{String, Any}(),  # data
        Dict{String, Tuple}(),  # tasks
        Dict{String, String}(),  #task_state
        Dict{String, Tuple}(),  # priorities
        0,  # priority_counter

        transitions,
        Deque{String}(),  # data_needed
        PriorityQueue(String, Tuple, Base.Order.ForwardOrdering()),  # ready
        Set{String}(),  # executing

        dep_transitions,
        Dict{String, String}(),  # dep_state
        Dict{String, Set}(),  # dependencies
        Dict{String, Set}(),  # dependents
        Dict{String, Set}(),  # waiting_for_data
        DefaultDict{String, Deque{String}}(Deque{String}),  # pending_data_per_worker
        Dict{String, Set{String}}(),  # who_has
        DefaultDict{String, Set{String}}(Set{String}),  # has_what

        Dict{String, String}(),  # in_flight_tasks
        Dict{String, Set{String}}(),  # in_flight_workers
        DefaultDict{String, Integer}(0),  # suspicious_deps
        Set{String}(),  # missing_dep_flight
    )

    start_worker(worker)
    return worker
end

"""
    shutdown(workers::Array{Address, 1})

Connect to and terminate all workers in `workers`.
"""
function shutdown(workers::Array{Address, 1})
    closed = Array{Address, 1}()
    for worker_address in workers
        clientside = connect(worker_address)
        msg = Dict("op" => "terminate", "reply" => true)
        response = send_recv(clientside, msg)
        response == "OK" || warn(logger, "Error closing worker at: \"$worker_address\"")
        response == "OK" && push!(closed, worker_address)
    end
    notice(logger, "Shutdown $(length(closed)) worker(s) at: $closed")
end

"""
    show(io::IO, worker::Worker)

Print a representation of the worker and it's state.
"""
function Base.show(io::IO, worker::Worker)
    @printf(
        io,
        "<%s: %s, %s, stored: %d, running: %d, ready: %d, comm: %d, waiting: %d>",
        typeof(worker).name.name, worker.address, worker.status,
        length(worker.data), length(worker.executing),
        length(worker.ready), length(worker.in_flight_tasks),
        length(worker.waiting_for_data),
    )
end

##############################         ADMIN FUNCTIONS        ##############################

"""
    start_worker(worker::Worker)

Coordinate a worker's startup.
"""
function start_worker(worker::Worker)
    worker.status == "starting" || return

    start_listening(worker)
    notice(
        logger,
        "Start worker at: \"$(worker.address)\", " *
        "waiting to connect to: \"$(worker.scheduler_address)\""
    )

    register_worker(worker)
end

"""
    register_worker(worker::Worker)

Register a `Worker` with the dask-scheduler process.
"""
function register_worker(worker::Worker)
    @async begin
        response = send_recv(
            worker.scheduler,
            Dict(
                "op" => "register",
                "address" => worker.address,
                "ncores" => Sys.CPU_CORES,
                "keys" => collect(keys(worker.data)),
                "now" => time(),
                "executing" => length(worker.executing),
                "in_memory" => length(worker.data),
                "ready" => length(worker.ready),
                "in_flight" => length(worker.in_flight_tasks),
                "memory_limit" => Sys.total_memory() * 0.6,
                "services" => Dict(),
            )
        )

        response == "OK" || error("Worker not registered. Check the scheduler is running.")
        worker.status = "running"
    end
end

"""
    handle_comm(worker::Worker, comm::TCPSocket)

Listen for incoming messages on an established connection.
"""
function handle_comm(worker::Worker, comm::TCPSocket)
    @async begin
        incoming_host, incoming_port = getsockname(comm)
        incoming_address = Address(incoming_host, incoming_port)
        info(logger, "Connection received from \"$incoming_address\"")

        op = ""
        is_computing = false

        while isopen(comm)
            msgs = []
            try
                msgs = recv_msg(comm)
             catch exception
                # EOFError's are expected when connections are closed unexpectedly
                isa(exception, EOFError) && break
                warn(
                    logger,
                    "Lost connection to \"$incoming_address\" " *
                    "while reading message: $exception. " *
                    "Last operation: \"$op\""
                )
                break
            end

            if isa(msgs, Dict)
                msgs = [msgs]
            end

            received_new_compute_stream_op = false

            for msg in msgs
                op = pop!(msg, "op", nothing)

                if op != nothing
                    reply = pop!(msg, "reply", nothing)
                    close_desired = pop!(msg, "close", nothing)

                    if op == "close"
                        if reply == "true" || reply == true
                            send_msg(comm, "OK")
                        end
                        close(comm)
                        break
                    end

                    msg = Dict(parse(k) => v for (k,v) in msg)

                    if is_computing && haskey(worker.compute_stream_handlers, op)
                        received_new_compute_stream_op = true

                        compute_stream_handler = worker.compute_stream_handlers[op]
                        compute_stream_handler(worker; msg...)

                    elseif op == "compute-stream"
                        is_computing = true
                        if isnull(worker.batched_stream)
                            worker.batched_stream = BatchedSend(comm, interval=0.002)
                        end
                    else

                        handler = worker.handlers[op]
                        result = handler(worker; msg...)

                        if reply == "true"
                            send_msg(comm, result)
                        end

                        if op == "terminate"
                            close(comm)
                            close(worker.listener)
                            return
                        end
                    end

                    if close_desired == "true"
                        close(comm)
                        break
                    end
                end
            end

            if received_new_compute_stream_op == true
                worker.priority_counter -= 1
                ensure_communicating(worker)
                ensure_computing(worker)
            end
        end

        close(comm)
    end
end

"""
    Base.close(worker::Worker; report::Bool=true)

Close the worker and all the connections it has open.
"""
function Base.close(worker::Worker; report::Bool=true)
    @async begin
        if worker.status ∉ ("closed", "closing")
            notice(logger, "Stopping worker at $(worker.address)")
            worker.status = "closing"

            if report
                response = send_recv(
                    worker.scheduler,
                    Dict("op" => "unregister", "address" => worker.address)
                )
                info(logger, "Scheduler closed connection to worker: \"$response\"")
            end

            isnull(worker.batched_stream) || close(get(worker.batched_stream))
            close(worker.scheduler)

            worker.status = "closed"
            close(worker.connection_pool)
        end
    end
end

##############################       HANDLER FUNCTIONS        ##############################

"""
    get_data(worker::Worker; keys::Array=[], who::String="")

Send the results of `keys` back over the stream they were requested on.
"""
function get_data(worker::Worker; keys::Array=[], who::String="")
    data = Dict(
        to_key(k) =>
        to_serialize(worker.data[k]) for k in filter(k -> haskey(worker.data, k), keys)
    )
    debug(logger, "\"get_data\": ($keys: \"$who\")")
    return data
end

"""
    gather(worker::Worker; who_has::Dict=Dict())

Gather the results for various keys.
"""
function gather(worker::Worker; who_has::Dict=Dict())
    who_has = filter((k,v) -> !haskey(worker.data, k), who_has)

    result, missing_keys, missing_workers = gather_from_workers(
        who_has,
        worker.connection_pool
    )
    if !isempty(missing_keys)
        warn(
            logger,
            "Could not find data: $missing_keys on workers: $missing_workers " *
            "(who_has: $who_has)"
        )
        return Dict("status" => "missing-data", "keys" => missing_keys)
    else
        update_data(worker, data=result, report="false")
        return Dict("status" => "OK")
    end
end


"""
    update_data(worker::Worker; data::Dict=Dict(), report::String="true")

Update the worker data.
"""
function update_data(worker::Worker; data::Dict=Dict(), report::String="true")
    for (key, value) in data
        if haskey(worker.task_state, key)
            transition(worker, key, "memory", value=value)
        else
            put_key_in_memory(worker, key, value)
            worker.task_state[key] = "memory"
            worker.dependencies[key] = Set()
        end

        haskey(worker.dep_state, key) && transition_dep(worker, key, "memory", value=value)
        debug(logger, "\"$key: \"receive-from-scatter\"")
    end

    if report == "true"
        send_msg(
            get(worker.batched_stream),
            Dict("op" => "add-keys", "keys" => collect(keys(data)))
        )
    end

    return Dict("nbytes" => Dict(k => sizeof(v) for (k,v) in data), "status" => "OK")
end

"""
    delete_data(worker::Worker; keys::Array=[], report::String="true")

Delete the data associated with each key of `keys` in `worker.data`.
"""
function delete_data(worker::Worker; keys::Array=[], report::String="true")
    @async begin
        for key in keys
            if haskey(worker.task_state, key)
                release_key(worker, key=key)
            end
            if haskey(worker.dep_state, key)
                release_dep(worker, key)
            end
        end
    end
end

"""
    terminate(worker::Worker; report::String="true")

Shutdown the worker and close all its connections.
"""
function terminate(worker::Worker; report::String="true")
    close(worker, report=parse(report))
    return "OK"
end

"""
    get_keys(worker::Worker) -> Array

Get a list of all the keys held by this worker.
"""
function get_keys(worker::Worker)
    return [to_key(key) for key in collect(keys(worker.data))]
end

##############################     COMPUTE-STREAM FUNCTIONS    #############################

"""
    add_task(worker::Worker; kwargs...)

Add a task to the worker's list of tasks to be computed.

# Keywords

- `key::String`: The tasks's unique identifier. Throws an exception if blank.
- `priority::Array`: The priority of the task. Throws an exception if blank.
- `who_has::Dict`: Map of dependent keys and the addresses of the workers that have them.
- `nbytes::Dict`: Map of the number of bytes of the dependent key's data.
- `duration::String`: The estimated computation cost of the given key. Defaults to "0.5".
- `resource_restrictions::Dict`: Resources required by a task. Should always be an empty Dict.
- `func::Union{String, Array{UInt8,1}}`: The callable funtion for the task, serialized.
- `args::Union{String, Array{UInt8,1}}`: The arguments for the task, serialized.
- `kwargs::Union{String, Array{UInt8,1}}`: The keyword arguments for the task, serialized.
- `future::Union{String, Array{UInt8,1}}`: The tasks's serialized `DeferredFuture`.
"""
function add_task(
    worker::Worker;
    key::String="",
    priority::Array=[],
    who_has::Dict=Dict(),
    nbytes::Dict=Dict(),
    duration::String="0.5",
    resource_restrictions::Dict=Dict(),
    func::Union{String, Array{UInt8,1}}="",
    args::Union{String, Array{UInt8,1}}="",
    kwargs::Union{String, Array{UInt8,1}}="",
    future::Union{String, Array{UInt8,1}}="",
)

    isempty(resource_restrictions) || error("Using resource restrictions is not supported")

    priority = map(parse, priority)
    insert!(priority, 2, worker.priority_counter)
    priority = tuple(priority...)

    if haskey(worker.tasks, key)
        state = worker.task_state[key]
        if state == "memory"
            @assert haskey(worker.data, key)
            info(logger, "Asked to compute pre-existing result: (\"$key\": \"$state\")")
            send_task_state_to_scheduler(worker, key)
        end
        return
    end

    if haskey(worker.dep_state, key) && worker.dep_state[key] == "memory"
        worker.task_state[key] = "memory"
        send_task_state_to_scheduler(worker, key)
        worker.tasks[key] = ()
        debug(logger, "\"$key\": \"new-task-already-in-memory\"")
        worker.priorities[key] = priority
        return
    end

    debug(logger, "\"$key\": \"new-task\"")
    try
        worker.tasks[key] = deserialize_task(func, args, kwargs, future)
    catch exception
        error_msg = Dict(
            "exception" => "$(typeof(exception)))",
            "traceback" => sprint(showerror, exception),
            "key" => to_key(key),
            "op" => "task-erred",
        )
        warn(
            logger,
            "Could not deserialize task: (\"$key\": $(error_msg["traceback"]))"
        )
        send_msg(get(worker.batched_stream), error_msg)
        return
    end

    worker.priorities[key] = priority
    worker.task_state[key] = "waiting"

    worker.dependencies[key] = Set(keys(who_has))
    worker.waiting_for_data[key] = Set()

    for dep in keys(who_has)
        if !haskey(worker.dependents, dep)
            worker.dependents[dep] = Set()
        end
        push!(worker.dependents[dep], key)

        if !haskey(worker.dep_state, dep)
            if haskey(worker.task_state, dep) && worker.task_state[dep] == "memory"
                worker.dep_state[dep] = "memory"
            else
                worker.dep_state[dep] = "waiting"
            end
        end

        if worker.dep_state[dep] != "memory"
            push!(worker.waiting_for_data[key], dep)
        end
    end

    for (dep, workers) in who_has
        @assert !isempty(workers)
        if !haskey(worker.who_has, dep)
            worker.who_has[dep] = Set(workers)
        end
        push!(worker.who_has[dep], workers...)

        for worker_addr in workers
            push!(worker.has_what[worker_addr], dep)
            if worker.dep_state[dep] != "memory"
                push!(worker.pending_data_per_worker[worker_addr], dep)
            end
        end
    end

    if !isempty(worker.waiting_for_data[key])
        push!(worker.data_needed, key)
    else
        transition(worker, key, "ready")
    end
end

"""
    release_key(worker::Worker; key::String, cause::String, reason::String)

Delete a key and its data.
"""
function release_key(
    worker::Worker;
    key::String="",
    cause::String="",
    reason::String=""
)
    haskey(worker.task_state, key) || return
    (reason == "stolen" && worker.task_state[key] in ("executing", "memory")) && return

    state = pop!(worker.task_state, key)
    debug(logger, "\"$key\": \"release-key\" $cause")

    delete!(worker.tasks, key)

    if haskey(worker.data, key) && !haskey(worker.dep_state, key)
        delete!(worker.data, key)
    end

    haskey(worker.waiting_for_data, key) && delete!(worker.waiting_for_data, key)

    for dep in pop!(worker.dependencies, key, ())
        if haskey(worker.dependents, dep)
            delete!(worker.dependents[dep], key)
            if isempty(worker.dependents[dep]) && worker.dep_state[dep] == "waiting"
                release_dep(worker, dep)
            end
        end
    end

    delete!(worker.priorities, key)
    key in worker.executing && delete!(worker.executing, key)

    if state in ("waiting", "ready", "executing") && !isnull(worker.batched_stream)
        send_msg(
            get(worker.batched_stream),
            Dict("op" => "release", "key" => to_key(key), "cause" => cause)
        )
    end
end

"""
    release_dep(worker::Worker, dep::String)

Delete a dependency key and its data.
"""
function release_dep(worker::Worker, dep::String)
    haskey(worker.dep_state, dep) || return

    debug(logger, "\"$dep\": \"release-dep\"")
    haskey(worker.dep_state, dep) && pop!(worker.dep_state, dep)

    haskey(worker.suspicious_deps, dep) && delete!(worker.suspicious_deps, dep)

    if !haskey(worker.task_state, dep)
        if haskey(worker.data, dep)
            delete!(worker.data, dep)
        end
    end

    haskey(worker.in_flight_tasks, dep) && delete!(worker.in_flight_tasks, dep)

    for key in pop!(worker.dependents, dep, ())
        delete!(worker.dependencies[key], dep)
        if !haskey(worker.task_state, key) || worker.task_state[key] != "memory"
            release_key(worker, key=key, cause=dep)
        end
    end
end

##############################       EXECUTING FUNCTIONS      ##############################

"""
    ensure_computing(worker::Worker)

Make sure the worker is computing available tasks.
"""
function ensure_computing(worker::Worker)
    while !isempty(worker.ready)
        key = dequeue!(worker.ready)
        if get(worker.task_state, key, nothing) == "ready"
            transition(worker, key, "executing")
        end
    end
end

"""
    execute(worker::Worker, key::String)

Execute the task identified by `key`.
"""
function execute(worker::Worker, key::String)
    @async begin
        (key in worker.executing && haskey(worker.task_state, key)) || return

        (func, args, kwargs, future) = worker.tasks[key]

        # TODO: check if future was already executed
        # if isa(future, DeferredFuture) && isready(future) && (value = fetch(future))

        args2 = pack_data(args, worker.data, key_types=String)
        kwargs2 = pack_data(kwargs, worker.data, key_types=String)

        result = apply_function(func, args2, kwargs2)

        get(worker.task_state, key, nothing) == "executing" || return

        result["key"] = key
        value = pop!(result, "result", nothing)

        # Ensure the task hasn't been released (cancelled) by the scheduler
        haskey(worker.tasks, key) || return

        if result["op"] == "task-erred"
            value = (result["exception"] => result["traceback"])
            warn(logger, "Compute Failed for key \"$key\": $value")
        end

        if isa(future, DeferredFuture)
            try
                !isready(future) && put!(future, value)
                # !isready(future) && (cond = @spawnat 1 put!(future, value))
                # wait(cond)
            catch exception
                notice(logger, "Remote exception on future for key \"$key\": $exception")
            end
        end
        transition(worker, key, "memory", value=value)

        info(logger, "Send compute response to scheduler: (\"$key\": \"$(result["op"])\")")

        ensure_computing(worker)
        ensure_communicating(worker)
    end
end

"""
    put_key_in_memory(worker::Worker, key::String, value; should_transition::Bool=true)

Store the result (`value`) of the task identified by `key`.
"""
function put_key_in_memory(worker::Worker, key::String, value; should_transition::Bool=true)
    haskey(worker.data, key) && return
    worker.data[key] = value

    for dep in get(worker.dependents, key, [])
        if haskey(worker.waiting_for_data, dep)
            if key in worker.waiting_for_data[dep]
                delete!(worker.waiting_for_data[dep], key)
            end
            if isempty(worker.waiting_for_data[dep])
                transition(worker, dep, "ready")
            end
        end
    end

    if should_transition && haskey(worker.task_state, key)
        transition(worker, key, "memory")
    end

    debug(logger, "\"$key\": \"put-in-memory\"")
end

##############################  PEER DATA GATHERING FUNCTIONS ##############################

"""
    ensure_communicating(worker::Worker)

Ensure the worker is communicating with its peers to gather dependencies as needed.
"""
function ensure_communicating(worker::Worker)
    changed = true
    while (
        changed &&
        !isempty(worker.data_needed) &&
        length(worker.in_flight_workers) < worker.total_connections
    )
        changed = false
        info(
            logger,
            "Ensure communicating.  " *
            "Pending: $(length(worker.data_needed)).  " *
            "Connections: $(length(worker.in_flight_workers))/$(worker.total_connections)"
        )

        # TODO: just pop the needed key right away?

        key = !isempty(worker.data_needed) ? front(worker.data_needed) : nothing
        key != nothing || return

        if !haskey(worker.tasks, key)
            !isempty(worker.data_needed) && key == front(worker.data_needed) && shift!(worker.data_needed)
            changed = true
            continue
        end

        if !haskey(worker.task_state, key) || worker.task_state[key] != "waiting"
            debug(logger, "\"$key\": \"communication pass\"")
            !isempty(worker.data_needed) && key == front(worker.data_needed) && shift!(worker.data_needed)
            changed = true
            continue
        end

        deps = collect(
            filter(dep -> (worker.dep_state[dep] == "waiting"), worker.dependencies[key])
        )

        missing_deps = Set(filter(dep -> !haskey(worker.who_has, dep), deps))

        if !isempty(missing_deps)
            warn(logger, "Could not find the dependencies for key \"$key\"")
            missing_deps2 = Set(filter(dep -> dep ∉ worker.missing_dep_flight, missing_deps))

            if !isempty(missing_deps2)
                push!(worker.missing_dep_flight, missing_deps2...)
                handle_missing_dep(worker, missing_deps2)
            end

            deps = collect(filter(dependency -> dependency ∉ missing_deps, deps))
        end

        debug(logger, "\"gather-dependencies\": (\"$key\": $deps)")
        in_flight = false

        while (
            !isempty(deps) && length(worker.in_flight_workers) < worker.total_connections
        )
            dep = pop!(deps)
            if worker.dep_state[dep] == "waiting" && haskey(worker.who_has, dep)
                workers = collect(
                    filter(w -> !haskey(worker.in_flight_workers, w), worker.who_has[dep])
                )
                if isempty(workers)
                    in_flight = true
                    continue
                end
                worker_addr = rand(workers)
                to_gather = select_keys_for_gather(worker, worker_addr, dep)

                worker.in_flight_workers[worker_addr] = to_gather

                for dep2 in to_gather
                    if get(worker.dep_state, dep2, nothing) == "waiting"
                        transition_dep(worker, dep2, "flight", worker_addr=worker_addr)
                    else
                        pop!(to_gather, dep2)
                    end
                end
                @sync gather_dep(worker, worker_addr, dep, to_gather, cause=key)
                changed = true
            end
        end

        if isempty(deps) && !in_flight && !isempty(worker.data_needed)
            key == front(worker.data_needed) && shift!(worker.data_needed)
        end
    end
end

"""
    gather_dep(worker::Worker, worker_addr::String, dep::String, deps::Set; cause::String="")

Gather the dependency with identifier "dep" from `worker_addr`.
"""
function gather_dep(
    worker::Worker,
    worker_addr::String,
    dep::String,
    deps::Set;
    cause::String=""
)
    @async begin
        worker.status != "running" && return
        response = Dict()

        debug(logger, "\"request-dep\": (\"$dep\", \"$worker_addr\", $deps)")
        info(logger, "Request $(length(deps)) keys")

        try
            response = send_recv(
                worker.connection_pool,
                Address(worker_addr),
                Dict(
                    "op" => "get_data",
                    "reply" => true,
                    "keys" => [to_key(key) for key in deps],
                    "who" => worker.address,
                )
            )

            debug(logger, "\"receive-dep\": (\"$worker_addr\", $(collect(keys(response))))")
            response = Dict(k => to_deserialize(v) for (k,v) in response)

            if !isempty(response)
                send_msg(
                    get(worker.batched_stream),
                    Dict("op" => "add-keys", "keys" => collect(keys(response)))
                )
            end
        catch exception
            warn(
                logger,
                "Worker stream died during communication \"$worker_addr\": $exception"
            )
            debug(logger, "\"received-dep-failed\": \"$worker_addr\"")

            for dep in pop!(worker.has_what, worker_addr)
                delete!(worker.who_has[dep], worker_addr)
                if haskey(worker.who_has, dep) && isempty(worker.who_has[dep])
                    delete!(worker.who_has, dep)
                end
            end
        end

        for dep in pop!(worker.in_flight_workers, worker_addr)
            if haskey(response, dep)
                transition_dep(worker, dep, "memory", value=response[dep])
            elseif !haskey(worker.dep_state, dep) || worker.dep_state[dep] != "memory"
                transition_dep(worker, dep, "waiting", worker_addr=worker_addr)
            end

            if !haskey(response, dep) && haskey(worker.dependents, dep)
                debug(logger, "\"missing-dep\": \"$dep\"")
            end
        end

        ensure_computing(worker)
        ensure_communicating(worker)
    end
end


"""
    handle_missing_dep(worker::Worker, deps::Set{String})

Handle a missing dependency that can't be found on any peers.
"""
function handle_missing_dep(worker::Worker, deps::Set{String})
    @async begin
        !isempty(deps) || return
        original_deps = deps
        debug(logger, "\"handle-missing\": $deps")

        deps = filter(dep -> haskey(worker.dependents, dep), deps)

        for dep in deps
            suspicious = worker.suspicious_deps[dep]
            if suspicious > 3
                delete!(deps, dep)
                bad_dep(worker, dep)
            end
        end

        !isempty(deps) || return
        info(logger, "Dependents not found: $deps. Asking scheduler")

        who_has = send_recv(
            worker.scheduler,
            Dict("op" => "who_has", "keys" => [to_key(key) for key in deps])
        )
        who_has = filter((k,v) -> !isempty(v), who_has)
        update_who_has(worker, who_has)

        for dep in deps
            worker.suspicious_deps[dep] += 1

            if !haskey(who_has, dep)
                dependent = get(worker.dependents, dep, nothing)
                debug(logger, "\"$dep\": (\"no workers found\": \"$dependent\")")
                release_dep(worker, dep)
            else
                debug(logger, "\"$dep\": \"new workers found\"")
                for key in get(worker.dependents, dep, ())
                    if haskey(worker.waiting_for_data, key)
                        push!(worker.data_needed, key)
                    end
                end
            end
        end

        for dep in original_deps
            delete!(worker.missing_dep_flight, dep)
        end

        ensure_communicating(worker)
    end
end

"""
    bad_dep(worker::Worker, dep::String)

Handle a bad dependency.
"""
function bad_dep(worker::Worker, dep::String)
    for key in worker.dependents[dep]
        err = ErrorException("Could not find dependent \"$dep\".  Check worker logs")
        transition(worker, key, "memory", value=(err => StackFrame[]))
    end
    release_dep(worker, dep)
end

"""
    update_who_has(worker::Worker, who_has::Dict{String, Array{Any, 1}})

Ensure `who_has` is up to date and accurate.
"""
function update_who_has(worker::Worker, who_has::Dict{String, Array{Any, 1}})
    for (dep, workers) in who_has
        if !isempty(workers)
            if haskey(worker.who_has, dep)
                push!(worker.who_has[dep], workers...)
            else
                worker.who_has[dep] = Set(workers)
            end

            for worker_address in workers
                push!(worker.has_what[worker_address], dep)
            end
        end
    end
end

"""
    select_keys_for_gather(worker::Worker, worker_addr::String, dep::String)

Select which keys to gather from peer at `worker_addr`.
"""
function select_keys_for_gather(worker::Worker, worker_addr::String, dep::String)
    deps = Set([dep])
    pending = worker.pending_data_per_worker[worker_addr]

    while !isempty(pending)
        dep = shift!(pending)

        (!haskey(worker.dep_state, dep) || worker.dep_state[dep] != "waiting") && continue

        push!(deps, dep)
    end

    return deps
end

"""
    gather_from_workers(who_has::Dict, connection_pool::ConnectionPool)

Gather data directly from `who_has` peers.
"""
function gather_from_workers(who_has::Dict, connection_pool::ConnectionPool)
    bad_addresses = Set()
    missing_workers = Set()
    original_who_has = who_has
    who_has = Dict(k => Set(v) for (k,v) in who_has)
    results = Dict()
    all_bad_keys = Set()

    while length(results) + length(all_bad_keys) < length(who_has)
        directory = Dict{String, Array}()
        rev = Dict()
        bad_keys = Set()

        for (key, addresses) in who_has

            haskey(results, key) && continue
            if isempty(addresses)
                push!(all_bad_keys, key)
                continue
            end

            possible_addresses = collect(setdiff(addresses, bad_addresses))
            if isempty(possible_addresses)
                push!(all_bad_keys, key)
                continue
            end

            address = rand(possible_addresses)
            !haskey(directory, address) && (directory[address] = [])
            push!(directory[address], key)
            rev[key] = address
        end

        !isempty(bad_keys) && union!(all_bad_keys, bad_keys)

        responses = Dict()
        for (address, keys_to_gather) in directory
            response = nothing
            try
                response = send_recv(
                    connection_pool,
                    Address(address),
                    Dict(
                        "op" => "get_data",
                        "reply" => true,
                        "keys" => keys_to_gather,
                        "close" => false,
                    ),
                )
            catch exception
                warn(
                    logger,
                    "Worker stream died during communication \"$address\": $exception"
                )
                push!(missing_workers, address)
            finally
                merge!(responses, response)
            end
        end

        union!(bad_addresses, Set(v for (k, v) in rev if !haskey(responses, k)))
        merge!(results, responses)
    end

    bad_keys = Dict(k => collect(original_who_has[k]) for k in all_bad_keys)

    return results, bad_keys, collect(missing_workers)
end

##############################      TRANSITION FUNCTIONS      ##############################

"""
    transition(worker::Worker, key::String, finish_state::String; kwargs...)

Transition task with identifier `key` to finish_state from its current state.
"""
function transition(worker::Worker, key::String, finish_state::String; kwargs...)
     # Ensure the task hasn't been released (cancelled) by the scheduler
    if haskey(worker.tasks, key) && haskey(worker.task_state, key)
        start_state = worker.task_state[key]

        if start_state != finish_state
            transition_func = worker.transitions[start_state, finish_state]
            transition_func(worker, key, ;kwargs...)
            worker.task_state[key] = finish_state
        end
    end
end

function transition_waiting_ready(worker::Worker, key::String)
    delete!(worker.waiting_for_data, key)
    enqueue!(worker.ready, key, worker.priorities[key])
    delete!(worker.priorities, key)
end

function transition_waiting_done(worker::Worker, key::String; value::Any=nothing)
    delete!(worker.waiting_for_data, key)
    send_task_state_to_scheduler(worker, key)
end

function transition_ready_executing(worker::Worker, key::String)
    push!(worker.executing, key)
    execute(worker, key)
end

function transition_ready_memory(worker::Worker, key::String; value::Any=nothing)
    send_task_state_to_scheduler(worker, key)
end

function transition_executing_done(worker::Worker, key::String; value::Any=no_value)
    worker.task_state[key] == "executing" && delete!(worker.executing, key)

    if value != no_value
        put_key_in_memory(worker, key, value, should_transition=false)
        haskey(worker.dep_state, key) && transition_dep(worker, key, "memory")
    end

    send_task_state_to_scheduler(worker, key)
end

"""
    transition_dep(worker::Worker, dep::String, finish_state::String; kwargs...)

Transition dependency task with identifier `key` to finish_state from its current state.
"""
function transition_dep(worker::Worker, dep::String, finish_state::String; kwargs...)
    if haskey(worker.dep_state, dep)
        start_state = worker.dep_state[dep]

        if start_state != finish_state && !(start_state == "memory" && finish_state == "flight")
            func = worker.dep_transitions[(start_state, finish_state)]
            func(worker, dep, ;kwargs...)
            debug(logger, "\"$dep\": transition dependency $start_state => $finish_state")
        end
    end
end

function transition_dep_waiting_flight(worker::Worker, dep::String; worker_addr::String="")
    worker.in_flight_tasks[dep] = worker_addr
    worker.dep_state[dep] = "flight"
end

function transition_dep_flight_waiting(worker::Worker, dep::String; worker_addr::String="")
    delete!(worker.in_flight_tasks, dep)

    haskey(worker.who_has, dep) && delete!(worker.who_has[dep], worker_addr)
    haskey(worker.has_what, worker_addr) && delete!(worker.has_what[worker_addr], dep)

    if !haskey(worker.who_has, dep) || isempty(worker.who_has[dep])
        if dep ∉ worker.missing_dep_flight
            push!(worker.missing_dep_flight, dep)
            handle_missing_dep(worker, Set([dep]))
        end
    end

    for key in get(worker.dependents, dep, ())
        if worker.task_state[key] == "waiting"
            unshift!(worker.data_needed, key)
        end
    end

    if haskey(worker.dependents, dep) && isempty(worker.dependents[dep])
        release_dep(worker, dep)
    end
    worker.dep_state[dep] = "waiting"
end

function transition_dep_flight_memory(worker::Worker, dep::String; value=nothing)
    delete!(worker.in_flight_tasks, dep)
    worker.dep_state[dep] = "memory"
    put_key_in_memory(worker, dep, value)
end


function transition_dep_waiting_memory(worker::Worker, dep::String; value=nothing)
    worker.dep_state[dep] = "memory"
end

##############################      SCHEDULER FUNCTIONS       ##############################

"""
    send_task_state_to_scheduler(worker::Worker, key::String)

Send the state of task `key` to the scheduler.
"""
function send_task_state_to_scheduler(worker::Worker, key::String)
    haskey(worker.data, key) || return

    send_msg(
        get(worker.batched_stream),
        Dict(
            "op" => "task-finished",
            "status" => "OK",
            "key" => to_key(key),
            "nbytes" => sizeof(worker.data[key]),
        )
    )
end

##############################         OTHER FUNCTIONS        ##############################

"""
    deserialize_task(func, args, kwargs) -> Tuple

Deserialize task inputs and regularize to func, args, kwargs.

# Returns
- `Tuple`: The deserialized function, arguments and keyword arguments for the task.
"""
function deserialize_task(
    func::Union{String, Array},
    args::Union{String, Array},
    kwargs::Union{String, Array},
    future::Union{String, Array}
)
    !isempty(func) && (func = to_deserialize(func))
    !isempty(args) && (args = to_deserialize(args))
    !isempty(kwargs) && (kwargs = to_deserialize(kwargs))
    !isempty(future) && (future = to_deserialize(future))

    return (func, args, kwargs, future)
end

"""
    apply_function(func::Base.Callable, args::Any, kwargs::Any)

Run a function and return collected information.
"""
function apply_function(func::Base.Callable, args::Any, kwargs::Any)
    result_msg = Dict{String, Any}()
    try
        result = func(args..., kwargs...)
        result_msg["op"] = "task-finished"
        result_msg["status"] = "OK"
        result_msg["result"] = result
    catch exception
        # Necessary because of a bug with empty stacktraces
        # in base, but will be fixed in 0.6
        # see https://github.com/JuliaLang/julia/issues/19655
        trace = try
            catch_stacktrace()
        catch
            StackFrame[]
        end
        result_msg = Dict{String, Any}(
            "exception" => exception,
            "traceback" => trace,
            "op" => "task-erred"
        )
    end
    return result_msg
end
