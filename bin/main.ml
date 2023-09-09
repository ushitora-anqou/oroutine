[@@@warning "-32-69"]

let debug_print fmt =
  Printf.ksprintf
    (fun s ->
      print_endline s;
      flush stdout)
    fmt

let rec fib n = if n <= 1 then n else fib (n - 1) + fib (n - 2)

module PrioQueue = struct
  (* Thanks to: https://v2.ocaml.org/releases/4.01/htmlman/moduleexamples.html *)
  type ('a, 'b) node =
    | Leaf
    | Branch of 'a * 'b * ('a, 'b) node * ('a, 'b) node

  type ('a, 'b) t = { mutable root : ('a, 'b) node }

  let make () : ('a, 'b) t = { root = Leaf }

  let rec insert' q prio elt =
    match q with
    | Leaf -> Branch (prio, elt, Leaf, Leaf)
    | Branch (p, e, left, right) ->
        if prio <= p then Branch (prio, elt, insert' right p e, left)
        else Branch (p, e, insert' right prio elt, left)

  let insert q prio elt = q.root <- insert' q.root prio elt

  exception Queue_is_empty

  let rec remove_top = function
    | Leaf -> raise Queue_is_empty
    | Branch (_, _, left, Leaf) -> left
    | Branch (_, _, Leaf, right) -> right
    | Branch
        ( _,
          _,
          (Branch (lprio, lelt, _, _) as left),
          (Branch (rprio, relt, _, _) as right) ) ->
        if lprio <= rprio then Branch (lprio, lelt, remove_top left, right)
        else Branch (rprio, relt, left, remove_top right)

  let extract' = function
    | Leaf -> raise Queue_is_empty
    | Branch (prio, elt, _, _) as queue -> (prio, elt, remove_top queue)

  let extract q =
    let prio, elt, queue = extract' q.root in
    q.root <- queue;
    (prio, elt)

  let extract_opt q = try Some (extract q) with Queue_is_empty -> None

  let peek_opt q =
    match q.root with
    | Leaf -> None
    | Branch (prio, elt, _, _) -> Some (prio, elt)
end

module type S = sig
  type task = unit -> unit

  val go : task -> unit
  val yield : unit -> unit
  val sleep : float -> unit
end

module Oroutine : S = struct
  type task = unit -> unit
  type processor = { dom : unit Domain.t }
  type run_queue = { v : task Queue.t; mtx : Mutex.t; cond : Condition.t }
  type 'a with_mutex = { mtx : Mutex.t; v : 'a }

  type env = {
    q : run_queue;
    timed_tasks : (float (* end time *), task) PrioQueue.t with_mutex;
        (* should be sorted by end time in acending order *)
    timed_pipe_fds : Unix.file_descr * Unix.file_descr;
  }

  let with_lock mtx f =
    Mutex.lock mtx;
    Fun.protect ~finally:(fun () -> Mutex.unlock mtx) f

  let spawn (q : run_queue) f =
    with_lock q.mtx (fun () ->
        Queue.push f q.v;
        Condition.signal q.cond)

  let spawn_many (q : run_queue) fs =
    with_lock q.mtx (fun () ->
        Queue.add_seq q.v (List.to_seq fs);
        Condition.broadcast q.cond)

  type _ Effect.t += Yield : unit Effect.t | Timeout : float -> unit Effect.t

  let yield () = Effect.perform Yield
  let sleep duration = Effect.perform (Timeout duration)

  let handle_yield env f =
    Effect.Deep.try_with f ()
      Effect.Deep.
        {
          effc =
            (fun (type a) (eff : a Effect.t) ->
              match eff with
              | Yield ->
                  Some
                    (fun (k : (a, _) continuation) ->
                      spawn env.q (fun () -> continue k ()))
              | Timeout duration ->
                  Some
                    (fun (k : (a, _) continuation) ->
                      let end_time = Unix.gettimeofday () +. duration in
                      with_lock env.timed_tasks.mtx (fun () ->
                          PrioQueue.insert env.timed_tasks.v end_time (fun () ->
                              continue k ()));
                      Unix.write (snd env.timed_pipe_fds) (Bytes.make 1 '1') 0 1
                      (* FIXME: handle error *)
                      |> ignore;
                      ())
              | _ -> None);
        }

  let select_worker env () =
    let timed_pipe_read_fd = fst env.timed_pipe_fds in
    let rec loop () =
      let next_timeout =
        match
          with_lock env.timed_tasks.mtx (fun () ->
              PrioQueue.peek_opt env.timed_tasks.v)
        with
        | None -> -1.0
        | Some (t, _) ->
            let v = t -. Unix.gettimeofday () in
            if v < 0.0 then 0.0 else v
      in
      let read_fds, _write_fds, _ =
        Unix.select [ timed_pipe_read_fd ] [] [] next_timeout
      in

      if read_fds |> List.find_opt (( = ) timed_pipe_read_fd) |> Option.is_some
      then Unix.read timed_pipe_read_fd (Bytes.make 1 '0') 0 1 |> ignore;

      let now = Unix.gettimeofday () in
      let ready_tasks =
        with_lock env.timed_tasks.mtx (fun () ->
            let rec aux ready =
              match PrioQueue.peek_opt env.timed_tasks.v with
              | Some (t, task) when t <= now ->
                  PrioQueue.extract env.timed_tasks.v |> ignore;
                  aux (task :: ready)
              | _ -> ready
            in
            aux [])
      in
      spawn_many env.q ready_tasks;

      loop ()
    in
    loop ()

  let worker env () =
    let rec loop should_lock =
      if should_lock then Mutex.lock env.q.mtx;
      if Queue.is_empty env.q.v then (
        Condition.wait env.q.cond env.q.mtx;
        loop false)
      else
        let task = Queue.pop env.q.v in
        Mutex.unlock env.q.mtx;
        (try handle_yield env task with _ -> ());
        loop true
    in
    loop true

  let make_env () =
    let q =
      { v = Queue.create (); mtx = Mutex.create (); cond = Condition.create () }
    in
    let env =
      {
        q;
        timed_tasks = { mtx = Mutex.create (); v = PrioQueue.make () };
        timed_pipe_fds = Unix.pipe ~cloexec:true ();
      }
    in
    let _processors =
      Array.init (Domain.recommended_domain_count ()) (fun _ ->
          { dom = Domain.spawn (worker env) })
    in
    spawn q (select_worker env);
    env

  (**)
  let global_env = make_env ()
  let go f = spawn global_env.q f
end

let () =
  for i = 0 to 10000 do
    let duration = Random.float 20.0 in
    debug_print "spawn 1 %d %f" i duration;
    Oroutine.(
      go (fun () ->
          let begin_time = Unix.gettimeofday () in
          sleep duration;
          let end_time = Unix.gettimeofday () in
          debug_print "done 2 %d %f" i (end_time -. begin_time);
          ()))
  done;
  debug_print "waiting";
  Unix.sleep 100;
  debug_print "timeout";
  ()
