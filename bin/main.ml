[@@@warning "-32-69"]

let debug_print fmt =
  Printf.ksprintf
    (fun s ->
      print_endline s;
      flush stdout)
    fmt

let rec fib n = if n <= 1 then n else fib (n - 1) + fib (n - 2)

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
  type env = { processors : processor array; q : run_queue }

  let spawn q f =
    Mutex.lock q.mtx;
    Queue.push f q.v;
    Condition.signal q.cond;
    Mutex.unlock q.mtx

  type _ Effect.t += Yield : unit Effect.t | Timeout : float -> unit Effect.t

  let yield () = Effect.perform Yield
  let sleep duration = Effect.perform (Timeout duration)

  let handle_yield q f =
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
                      Thread.create
                        (fun () ->
                          Unix.sleepf duration;
                          spawn q (fun () -> continue k ()))
                        ()
                      |> ignore)
              | _ -> None);
        }

  let worker (q : run_queue) () =
    let rec loop should_lock =
      if should_lock then Mutex.lock q.mtx;
      if Queue.is_empty q.v then (
        Condition.wait q.cond q.mtx;
        loop false)
      else
        let task = Queue.pop q.v in
        Mutex.unlock q.mtx;
        (try handle_yield q task with _ -> ());
        loop true
    in
    loop true

  let make_env () =
    let q =
      { v = Queue.create (); mtx = Mutex.create (); cond = Condition.create () }
    in
    {
      q;
      processors =
        Array.init (Domain.recommended_domain_count ()) (fun _ ->
            { dom = Domain.spawn (worker q) });
    }

  (**)
  let global_env = make_env ()
  let go f = spawn global_env.q f
end

let () =
  for i = 0 to 100 do
    Oroutine.(
      go (fun () ->
          let begin_time = Unix.gettimeofday () in
          sleep 3.0;
          let end_time = Unix.gettimeofday () in
          debug_print "done 2 %d %f" i (end_time -. begin_time);
          ()))
  done;
  debug_print "waiting";
  Unix.sleep 10;
  debug_print "timeout";
  ()
