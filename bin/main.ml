[@@@warning "-32-69"]

let debug_print fmt =
  Printf.ksprintf
    (fun s ->
      print_endline s;
      flush stdout)
    fmt

let rec fib n = if n <= 1 then n else fib (n - 1) + fib (n - 2)
let iota n = List.init n (fun i -> i)

let list_take n l =
  let rec aux acc n = function
    | rest when n = 0 -> (List.rev acc, rest)
    | [] -> (List.rev acc, [])
    | x :: xs -> aux (x :: acc) (n - 1) xs
  in
  aux [] n l

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

  type timed_tasks_info = {
    q : (float (* end time *), task) PrioQueue.t;
    mtx : Mutex.t;
    read_fd : Unix.file_descr;
    write_fd : Unix.file_descr;
  }

  type env = { qs : run_queue array; timed : timed_tasks_info; wid : int }

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
    let q = env.qs.(env.wid) in
    Effect.Deep.try_with f ()
      Effect.Deep.
        {
          effc =
            (fun (type a) (eff : a Effect.t) ->
              match eff with
              | Yield ->
                  Some
                    (fun (k : (a, _) continuation) ->
                      spawn q (fun () -> continue k ()))
              | Timeout duration ->
                  Some
                    (fun (k : (a, _) continuation) ->
                      let end_time = Unix.gettimeofday () +. duration in
                      with_lock env.timed.mtx (fun () ->
                          PrioQueue.insert env.timed.q end_time (fun () ->
                              continue k ()));
                      Unix.write env.timed.write_fd (Bytes.make 1 '1') 0 1
                      (* FIXME: handle error *)
                      |> ignore;
                      ())
              | _ -> None);
        }

  let select_worker env () =
    let rec loop () =
      let next_timeout =
        match
          with_lock env.timed.mtx (fun () -> PrioQueue.peek_opt env.timed.q)
        with
        | None -> -1.0
        | Some (t, _) ->
            let v = t -. Unix.gettimeofday () in
            if v < 0.0 then 0.0 else v
      in
      let read_fds, _write_fds, _ =
        Unix.select [ env.timed.read_fd ] [] [] next_timeout
      in

      if read_fds |> List.find_opt (( = ) env.timed.read_fd) |> Option.is_some
      then Unix.read env.timed.read_fd (Bytes.make 1 '0') 0 1 |> ignore;

      let now = Unix.gettimeofday () in
      let ready_tasks =
        with_lock env.timed.mtx (fun () ->
            let rec aux ready =
              match PrioQueue.peek_opt env.timed.q with
              | Some (t, task) when t <= now ->
                  PrioQueue.extract env.timed.q |> ignore;
                  aux (task :: ready)
              | _ -> ready
            in
            aux [])
      in

      (* Schedule ready tasks *)
      (let nprocs = Array.length env.qs in
       let plan = Array.make nprocs [] in
       ready_tasks
       |> List.iteri (fun i task ->
              plan.(i mod nprocs) <- task :: plan.(i mod nprocs));
       let offset = Random.int nprocs in
       plan
       |> Array.iteri (fun i tasks ->
              spawn_many env.qs.((i + offset) mod nprocs) tasks));

      loop ()
    in
    try loop ()
    with e ->
      debug_print "select_worker: %s\n%s" (Printexc.to_string e)
        (Printexc.get_backtrace ())

  let worker env () =
    let q = env.qs.(env.wid) in
    let rec loop should_lock =
      if should_lock then Mutex.lock q.mtx;
      if Queue.is_empty q.v then (
        Condition.wait q.cond q.mtx;
        loop false)
      else
        let task = Queue.pop q.v in
        Mutex.unlock q.mtx;
        (try handle_yield env task with _ -> ());
        loop true
    in
    loop true

  let make_env () =
    let num_workers = Domain.recommended_domain_count () in
    let qs =
      Array.init num_workers (fun _ ->
          {
            v = Queue.create ();
            mtx = Mutex.create ();
            cond = Condition.create ();
          })
    in
    let env =
      let read_fd, write_fd = Unix.pipe ~cloexec:true () in
      {
        wid = 0 (* dummy *);
        qs;
        timed =
          { mtx = Mutex.create (); q = PrioQueue.make (); read_fd; write_fd };
      }
    in
    let _processors =
      Array.init (Domain.recommended_domain_count ()) (fun i ->
          { dom = Domain.spawn (worker { env with wid = i }) })
    in
    Domain.spawn (select_worker env) |> ignore;
    env

  (**)
  let global_env = make_env ()
  let go f = spawn global_env.qs.(0) f
end

let () =
  let root_time = Unix.gettimeofday () in
  for i = 0 to 100000 do
    (*debug_print "spawn 1 %d %f" i duration;*)
    Oroutine.(
      go (fun () ->
          let begin_time = Unix.gettimeofday () in
          sleep (float_of_int i *. 0.0001);
          let end_time = Unix.gettimeofday () in
          if i mod 1000 = 0 then
            debug_print "done 2 %d %f %f" i (end_time -. begin_time)
              (end_time -. root_time);
          ()))
  done;
  debug_print "waiting %f" (Unix.gettimeofday () -. root_time);
  Unix.sleep 200;
  debug_print "timeout";
  ()
